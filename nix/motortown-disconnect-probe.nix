# Read-only mass-disconnect & replication-saturation correlator for Motor Town.
#
# Motivation: when the server hits SteamNetworkingSockets / UE5 outbound send
# limits (e.g. high NPC traffic density near clustered players), GameThread
# stays at ~120 FPS (so HangWatchdog and motortown-hang-probe never fire) and
# ICMP WAN probes show 0% loss, yet multiple players disconnect within seconds
# with stallMs < 100 ms.
#
# This service tails motortown.log and, whenever >= 2 players disconnect within
# 15 s (excluding server startup/restarts), writes a single forensic snapshot to
# /var/log/motortown-disconnect-probe.log correlating:
#   - drop classification (FREEZE vs TIMEOUT vs SEND_LIMIT_OR_TRANSPORT)
#   - live 2 s NIC tx/rx KB/s, UDP pps, NIC drops, and TX KB/s per player
#   - player locations & 100 m clustering from :5001/players
#   - active Valve SDR relay IPs from /proc/net/nf_conntrack + 3-ping RTT/loss
#   - recent TickProfiler lines from UE4SS.log + recent wan-probe.log lines
#
# STRICTLY READ-ONLY: never signals, kills, or modifies the game server.
{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.services.motortown-disconnect-probe;

  probeScript =
    pkgs.writers.writePython3 "motortown-disconnect-probe.py" {
      flakeIgnore = ["E501" "E302" "E305" "E231" "E265" "W503"];
    } ''
      #!${pkgs.python3}/bin/python3
      import json
      import math
      import os
      import re
      import signal
      import subprocess
      import time
      import urllib.request
      from datetime import datetime, timedelta, timezone

      SRV_LOG = ${builtins.toJSON cfg.serverLog}
      UE4SS_LOG = ${builtins.toJSON cfg.ue4ssLog}
      WAN_LOG = ${builtins.toJSON cfg.wanLog}
      OUT_LOG = ${builtins.toJSON cfg.logFile}
      IFACE = ${builtins.toJSON cfg.interface}
      PLAYERS_URL = ${builtins.toJSON cfg.playersUrl}
      CLUSTER_WINDOW_S = 15.0
      MIN_DROPS = 2
      SNAPSHOT_COOLDOWN_S = 30.0
      RESTART_SUPPRESS_S = 30.0
      MAX_LOG_BYTES = 10 * 1024 * 1024

      LOGOUT_RE = re.compile(
          r"Player Logout:\s+(.+?)\s+\((\d+)\)\s+stallMs=(\d+)\s+replFail=(\d+)"
      )
      CONNTRACK_DST_RE = re.compile(r"dst=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)")
      CONNTRACK_DPORT_RE = re.compile(r"dport=(\d+)")

      running = True

      def _stop(_signum, _frame):
          global running
          running = False

      signal.signal(signal.SIGTERM, _stop)
      signal.signal(signal.SIGINT, _stop)

      def timestamps():
          utc = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
          bk = datetime.now(timezone(timedelta(hours=7))).strftime("%Y-%m-%d %H:%M:%S+07")
          return utc, bk

      def rotate_if_needed():
          try:
              if os.path.getsize(OUT_LOG) > MAX_LOG_BYTES:
                  os.replace(OUT_LOG, OUT_LOG + ".1")
          except OSError:
              pass

      def append_block(lines):
          rotate_if_needed()
          text = "\n".join(lines) + "\n"
          try:
              with open(OUT_LOG, "a", encoding="utf-8") as fh:
                  fh.write(text)
          except OSError:
              pass
          print(text, end="", flush=True)

      def read_iface():
          try:
              with open("/proc/net/dev", encoding="utf-8") as fh:
                  for line in fh.read().splitlines()[2:]:
                      if ":" not in line:
                          continue
                      name, rest = line.split(":", 1)
                      if name.strip() == IFACE:
                          c = rest.split()
                          if len(c) >= 12:
                              return int(c[0]), int(c[3]), int(c[8]), int(c[11])
          except (OSError, ValueError):
              pass
          return None

      def read_udp():
          try:
              with open("/proc/net/snmp", encoding="utf-8") as fh:
                  lines = fh.read().splitlines()
              for i in range(len(lines) - 1):
                  if lines[i].startswith("Udp:"):
                      d = dict(zip(lines[i].split()[1:], lines[i + 1].split()[1:]))
                      return (
                          int(d.get("InDatagrams", 0)),
                          int(d.get("OutDatagrams", 0)),
                          int(d.get("RcvbufErrors", 0)),
                          int(d.get("InErrors", 0)),
                      )
          except (OSError, ValueError, IndexError):
              pass
          return None

      def sample_net(duration=2.0):
          n1, u1 = read_iface(), read_udp()
          time.sleep(duration)
          n2, u2 = read_iface(), read_udp()
          res = {}
          if n1 and n2:
              res["rx_kbps"] = (n2[0] - n1[0]) / 1024.0 / duration
              res["rx_drop_delta"] = n2[1] - n1[1]
              res["tx_kbps"] = (n2[2] - n1[2]) / 1024.0 / duration
              res["tx_drop_delta"] = n2[3] - n1[3]
          if u1 and u2:
              res["udp_in_pps"] = (u2[0] - u1[0]) / duration
              res["udp_out_pps"] = (u2[1] - u1[1]) / duration
              res["udp_rcvbuf_err"] = u2[2] - u1[2]
              res["udp_in_err"] = u2[3] - u1[3]
          return res

      def fetch_players():
          try:
              with urllib.request.urlopen(PLAYERS_URL, timeout=2.0) as resp:
                  data = json.load(resp).get("data") or {}
              if isinstance(data, dict):
                  return list(data.values())
          except Exception:
              pass
          return None

      def cluster_summary(players):
          if not players:
              return "count=0"
          coords = []
          for p in players:
              loc = p.get("location") or {}
              if isinstance(loc, dict) and "x" in loc and "y" in loc:
                  coords.append((p.get("name", "?"), float(loc["x"]), float(loc["y"])))
          max_near = 0
          for i, (_, x1, y1) in enumerate(coords):
              near = sum(
                  1 for _, x2, y2 in coords
                  if math.hypot(x2 - x1, y2 - y1) <= 10000.0  # 100 m in UE cm
              )
              if near > max_near:
                  max_near = near
          return "count={} max_within_100m={}".format(len(players), max_near)

      def active_sdr_relays(limit=4):
          relays = []
          seen = set()
          try:
              with open("/proc/net/nf_conntrack", encoding="utf-8") as fh:
                  for line in fh:
                      if "udp" not in line or "[ASSURED]" not in line:
                          continue
                      dm = CONNTRACK_DST_RE.search(line)
                      pm = CONNTRACK_DPORT_RE.search(line)
                      if not dm or not pm:
                          continue
                      ip = dm.group(1)
                      dport = int(pm.group(1))
                      if 27000 <= dport <= 27200 and not ip.startswith(("127.", "192.168.", "10.", "100.")):
                          if ip not in seen:
                              seen.add(ip)
                              relays.append(ip)
                              if len(relays) >= limit:
                                  break
          except OSError:
              pass
          return relays

      def ping_relay(ip):
          ping_bin = "/run/wrappers/bin/ping" if os.path.exists("/run/wrappers/bin/ping") else "ping"
          try:
              out = subprocess.check_output(
                  [ping_bin, "-n", "-c", "3", "-W", "1", "-q", ip],
                  stderr=subprocess.STDOUT,
                  text=True,
                  timeout=6,
              )
              lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
              summary = " | ".join(lines[-2:]) if len(lines) >= 2 else (lines[-1] if lines else "no-output")
              return "{}: {}".format(ip, summary)
          except Exception as exc:
              return "{}: ping-error {}".format(ip, exc)

      def tail_matching(path, needle=None, limit=3):
          try:
              with open(path, encoding="utf-8", errors="replace") as fh:
                  # Read last 64 KB to keep memory bounded
                  fh.seek(0, os.SEEK_END)
                  size = fh.tell()
                  fh.seek(max(0, size - 65536))
                  lines = fh.read().splitlines()
              if needle:
                  lines = [ln for ln in lines if needle in ln]
              return lines[-limit:]
          except OSError:
              return ["(unreadable: {})".format(path)]

      def classify(events):
          max_stall = max(e[2] for e in events)
          if max_stall >= 5000:
              return "FREEZE"
          if max_stall >= 1000:
              return "TIMEOUT"
          return "SEND_LIMIT_OR_TRANSPORT"

      def emit_snapshot(events):
          utc, bk = timestamps()
          kind = classify(events)
          net = sample_net(2.0)
          players = fetch_players()
          p_count = len(players) if players is not None else 0
          tx_kbps = net.get("tx_kbps")
          tx_per_p = (tx_kbps / p_count) if (tx_kbps is not None and p_count > 0) else None

          lines = [
              "===================================================================",
              "=== MASS_DISCONNECT {} (+07 {}) class={} drops={}".format(utc, bk, kind, len(events)),
              "### dropped players ({}s window)".format(int(CLUSTER_WINDOW_S)),
          ]
          for _, name, stall, repl in events:
              lines.append("  - {} stallMs={} replFail={}".format(name, stall, repl))

          lines.append("### live network (2s sample on {})".format(IFACE))
          lines.append(
              "  rx_kbps={} tx_kbps={} tx_per_player_kbps={} udp_in_pps={} udp_out_pps={} "
              "rx_drop_delta={} tx_drop_delta={} udp_rcvbuf_err={} udp_in_err={}".format(
                  "-" if "rx_kbps" not in net else "{:.1f}".format(net["rx_kbps"]),
                  "-" if tx_kbps is None else "{:.1f}".format(tx_kbps),
                  "-" if tx_per_p is None else "{:.1f}".format(tx_per_p),
                  "-" if "udp_in_pps" not in net else "{:.1f}".format(net["udp_in_pps"]),
                  "-" if "udp_out_pps" not in net else "{:.1f}".format(net["udp_out_pps"]),
                  net.get("rx_drop_delta", "-"),
                  net.get("tx_drop_delta", "-"),
                  net.get("udp_rcvbuf_err", "-"),
                  net.get("udp_in_err", "-"),
              )
          )

          lines.append("### live players")
          lines.append("  " + (cluster_summary(players) if players is not None else "api-unreachable"))

          lines.append("### active Valve SDR relays")
          relays = active_sdr_relays()
          if relays:
              for ip in relays:
                  lines.append("  " + ping_relay(ip))
          else:
              lines.append("  (none found in nf_conntrack)")

          lines.append("### recent TickProfiler")
          for ln in tail_matching(UE4SS_LOG, "[TickProfiler]", 3):
              lines.append("  " + ln)

          lines.append("### recent wan-probe")
          for ln in tail_matching(WAN_LOG, None, 3):
              lines.append("  " + ln)

          append_block(lines)

      def tail_loop():
          fh = None
          inode = None
          recent_drops = []
          last_snapshot = 0.0
          suppress_until = 0.0

          while running:
              try:
                  st = os.stat(SRV_LOG)
              except OSError:
                  time.sleep(2.0)
                  continue

              if fh is None or st.st_ino != inode or st.st_size < fh.tell():
                  if fh is not None:
                      fh.close()
                  try:
                      fh = open(SRV_LOG, encoding="utf-8", errors="replace")
                      # On initial attach, seek to end; on rotation, read from start.
                      if inode is None:
                          fh.seek(0, os.SEEK_END)
                      inode = st.st_ino
                  except OSError:
                      fh = None
                      time.sleep(2.0)
                      continue

              line = fh.readline()
              if not line:
                  time.sleep(0.5)
                  continue

              now = time.time()
              if "DedicatedServer is started" in line:
                  suppress_until = now + RESTART_SUPPRESS_S
                  recent_drops.clear()
                  continue

              m = LOGOUT_RE.search(line)
              if not m:
                  continue

              if now < suppress_until:
                  continue

              name = m.group(1)
              stall = int(m.group(3))
              repl = int(m.group(4))
              recent_drops.append((now, name, stall, repl))
              cutoff = now - CLUSTER_WINDOW_S
              recent_drops = [e for e in recent_drops if e[0] >= cutoff]

              if len(recent_drops) >= MIN_DROPS and (now - last_snapshot) >= SNAPSHOT_COOLDOWN_S:
                  last_snapshot = now
                  emit_snapshot(list(recent_drops))

          if fh is not None:
              fh.close()

      tail_loop()
    '';
in {
  options.services.motortown-disconnect-probe = {
    enable = lib.mkEnableOption "the read-only Motor Town mass-disconnect & replication correlator";
    serverLog = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/motortown-server/MotorTown/Saved/ServerLog/motortown.log";
      description = "Motor Town server log to tail for Player Logout clusters.";
    };
    ue4ssLog = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/motortown-server/MotorTown/Binaries/Win64/ue4ss/UE4SS.log";
      description = "UE4SS log path for TickProfiler snapshots.";
    };
    wanLog = lib.mkOption {
      type = lib.types.str;
      default = "/var/log/wan-probe.log";
      description = "WAN probe log path for correlation.";
    };
    logFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/log/motortown-disconnect-probe.log";
      description = "Forensic snapshot output log (rotated above 10 MB).";
    };
    interface = lib.mkOption {
      type = lib.types.str;
      default = "enp11s0";
      description = "WAN interface sampled on disconnect clusters.";
    };
    playersUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:5001/players";
      description = "Local mod-server players endpoint for count & clustering.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.motortown-disconnect-probe = {
      description = "Read-only Motor Town mass-disconnect & replication-saturation correlator";
      documentation = ["https://github.com/ASEAN-Motor-Club/amc-server"];
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      path = with pkgs; [iputils python3 tzdata];
      serviceConfig = {
        Type = "simple";
        ExecStart = probeScript;
        Restart = "always";
        RestartSec = 5;
        # CAP_NET_RAW for pinging active SDR relays; CAP_DAC_READ_SEARCH for
        # reading motortown.log / UE4SS.log inside 0700 /var/lib/motortown-server.
        CapabilityBoundingSet = ["CAP_NET_RAW" "CAP_DAC_READ_SEARCH"];
        AmbientCapabilities = ["CAP_NET_RAW"];
        ProtectSystem = "full";
        ReadWritePaths = ["/var/log"];
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
      };
      environment.TZ = "Asia/Bangkok";
    };
  };
}
