# Continuous read-only WAN connectivity probe for the game server host.
#
# Motivation: the ASEAN-Motor-Club server sits behind a consumer WAN (AIS) and
# players report intermittent disconnects. To correlate those with the actual
# link this service continuously pings three hops every second:
#   192.168.1.1    - local router
#   1.1.1.1        - Cloudflare BKK (nearest anycast, tests the ISP uplink)
#   103.10.124.1   - Valve Singapore SDR relay (what players actually reach)
# and logs:
#   - a quiet summary line every 5 minutes (per-target sent/recv/loss%
#     min/avg/max ms),
#   - an immediate anomaly line whenever any target shows packet loss in a
#     10 s window, >= 2 consecutive drops, or RTT > 150 ms — with exact UTC +
#     Asia/Bangkok timestamps, per-target status, and interface rx/tx dropped
#     deltas plus UDP RcvbufErrors/InErrors deltas for correlation with the
#     game server's own UDP pressure.
#
# STRICTLY READ-ONLY: the script never changes any network state, never
# signals, kills or restarts anything. It only pings and reads /proc.
{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.services.wan-probe;

  probeScript =
    pkgs.writers.writePython3 "wan-probe.py" {
      flakeIgnore = ["E501" "E302" "E305" "E231" "E265" "W503"];
    } ''
      #!${pkgs.python3}/bin/python3
      import json
      import os
      import re
      import signal
      import subprocess
      import threading
      import time
      import urllib.request
      from datetime import datetime, timezone

      TARGETS = ${builtins.toJSON cfg.targets}
      LOG = ${builtins.toJSON cfg.logFile}
      IFACE = ${builtins.toJSON cfg.interface}
      PLAYERS_URL = ${builtins.toJSON cfg.playersUrl}
      TX_PER_PLAYER_KBPS_THRESHOLD = ${toString cfg.txPerPlayerKbpsThreshold}
      UDP_OUT_PER_PLAYER_PPS_THRESHOLD = ${toString cfg.udpOutPerPlayerPpsThreshold}
      RTT_THRESHOLD_MS = 150.0
      WINDOW_SECONDS = 10
      SUMMARY_INTERVAL = 300  # 5 minutes
      PRESSURE_INTERVAL = 15  # 15 s check; 2 consecutive = 30 s sustained
      ANOMALY_MIN_GAP = 10    # at most one anomaly line / 10 s per target
      MAX_LOG_BYTES = 10 * 1024 * 1024  # rotate above 10 MB, keep one .log.1

      running = True

      def _stop(_signum, _frame):
          global running
          running = False

      signal.signal(signal.SIGTERM, _stop)
      signal.signal(signal.SIGINT, _stop)

      def now_epoch():
          return time.time()

      def timestamps():
          utc = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
          local = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
          # Force +07 rendering even if the service env lacks a proper tzdata.
          bangkok = datetime.now(timezone(__import__("datetime").timedelta(hours=7)))
          bk = bangkok.strftime("%Y-%m-%d %H:%M:%S+07")
          return utc, bk, local

      def rotate_if_needed():
          try:
              if os.path.getsize(LOG) > MAX_LOG_BYTES:
                  os.replace(LOG, LOG + ".1")
          except OSError:
              pass

      def log_line(line):
          rotate_if_needed()
          try:
              with open(LOG, "a", encoding="utf-8") as fh:
                  fh.write(line + "\n")
          except OSError:
              pass
          print(line, flush=True)

      # ---- system counters (read-only /proc reads) ---------------------------

      def iface_stats():
          """Return (rx_bytes, rx_dropped, tx_bytes, tx_dropped) for IFACE, or None."""
          try:
              with open("/proc/net/dev", encoding="utf-8") as fh:
                  for line in fh.read().splitlines()[2:]:
                      if ":" not in line:
                          continue
                      name, rest = line.split(":", 1)
                      if name.strip() == IFACE:
                          cols = rest.split()
                          if len(cols) >= 12:
                              return int(cols[0]), int(cols[3]), int(cols[8]), int(cols[11])
          except (OSError, ValueError):
              pass
          return None

      def udp_stats():
          """Return (RcvbufErrors, InErrors, InDatagrams, OutDatagrams) from /proc/net/snmp, or None."""
          try:
              with open("/proc/net/snmp", encoding="utf-8") as fh:
                  lines = fh.read().splitlines()
              for i in range(len(lines) - 1):
                  if lines[i].startswith("Udp:"):
                      keys = lines[i].split()[1:]
                      vals = lines[i + 1].split()[1:]
                      d = dict(zip(keys, vals))
                      return (
                          int(d.get("RcvbufErrors", 0)),
                          int(d.get("InErrors", 0)),
                          int(d.get("InDatagrams", 0)),
                          int(d.get("OutDatagrams", 0)),
                      )
          except (OSError, ValueError, IndexError):
              pass
          return None

      def fetch_player_count():
          """Return active player count from local mod-server API, or None."""
          if not PLAYERS_URL:
              return None
          try:
              with urllib.request.urlopen(PLAYERS_URL, timeout=1.0) as resp:
                  data = json.load(resp).get("data")
              if isinstance(data, (list, dict)):
                  return len(data)
          except Exception:
              pass
          return None

      last_iface = None
      last_udp = None
      last_counter_ts = None

      def counter_deltas():
          global last_iface, last_udp, last_counter_ts
          now = now_epoch()
          cur = iface_stats()
          udp = udp_stats()
          dt = (now - last_counter_ts) if last_counter_ts is not None else 0.0
          last_counter_ts = now

          if cur is not None and last_iface is None:
              last_iface = cur
          if udp is not None and last_udp is None:
              last_udp = udp

          rx_d = tx_d = rcv_d = in_d = None
          rx_kbps = tx_kbps = udp_out_pps = None
          if cur is not None and last_iface is not None:
              rx_d = cur[1] - last_iface[1]
              tx_d = cur[3] - last_iface[3]
              if dt > 0.5:
                  rx_kbps = (cur[0] - last_iface[0]) / 1024.0 / dt
                  tx_kbps = (cur[2] - last_iface[2]) / 1024.0 / dt
              last_iface = cur
          if udp is not None and last_udp is not None:
              rcv_d = udp[0] - last_udp[0]
              in_d = udp[1] - last_udp[1]
              if dt > 0.5:
                  udp_out_pps = (udp[3] - last_udp[3]) / dt
              last_udp = udp
          return rx_d, tx_d, rcv_d, in_d, rx_kbps, tx_kbps, udp_out_pps

      # ---- per-target ping threads -------------------------------------------

      # results[target] = list of (epoch, ok, rtt_ms_or_None), newest last
      results = {t: [] for t in TARGETS}
      consecutive = {t: 0 for t in TARGETS}
      last_anomaly = {t: 0.0 for t in TARGETS}
      totals = {t: {"sent": 0, "recv": 0, "rtts": []} for t in TARGETS}
      lock = threading.Lock()

      def prune_window(epoch):
          cutoff = epoch - WINDOW_SECONDS
          for t in TARGETS:
              res = results[t]
              while res and res[0][0] < cutoff:
                  res.pop(0)

      def window_status(target):
          """Human-readable per-target status from the current 10 s window."""
          res = results[target]
          sent = len(res)
          recv = sum(1 for _, ok, _ in res if ok)
          rtts = [r for _, ok, r in res if ok and r is not None]
          if rtts:
              fmt = "{}/{} {:.0f}% {:.1f}/{:.1f}/{:.1f}ms".format(
                  recv, sent, 100.0 * (sent - recv) / sent if sent else 0.0,
                  min(rtts), sum(rtts) / len(rtts), max(rtts))
          else:
              fmt = "{}/{} {:.0f}% -/-/-".format(
                  recv, sent, 100.0 * (sent - recv) / sent if sent else 0.0)
          return fmt

      def anomaly(target, reason):
          epoch = now_epoch()
          if epoch - last_anomaly[target] < ANOMALY_MIN_GAP:
              return
          last_anomaly[target] = epoch
          utc, bk, local = timestamps()
          rx_d, tx_d, rcv_d, in_d, rx_kbps, tx_kbps, udp_out_pps = counter_deltas()
          parts = []
          for t in TARGETS:
              parts.append("{}: {}".format(t, window_status(t)))
          line = ("ANOMALY {} (+07 {}) [{}] target={} reason={} | {}"
                  " | {} rx_kbps={} tx_kbps={} udp_out_pps={} rx_drop_delta={} tx_drop_delta={}"
                  " | udp RcvbufErrors_delta={} InErrors_delta={}"
                  .format(utc, bk, local, target, reason,
                          " ".join(parts), IFACE,
                          "-" if rx_kbps is None else "{:.1f}".format(rx_kbps),
                          "-" if tx_kbps is None else "{:.1f}".format(tx_kbps),
                          "-" if udp_out_pps is None else "{:.1f}".format(udp_out_pps),
                          "-" if rx_d is None else rx_d,
                          "-" if tx_d is None else tx_d,
                          "-" if rcv_d is None else rcv_d,
                          "-" if in_d is None else in_d))
          log_line(line)

      def record(target, ok, rtt):
          epoch = now_epoch()
          with lock:
              results[target].append((epoch, ok, rtt))
              prune_window(epoch)
              totals[target]["sent"] += 1
              if ok:
                  totals[target]["recv"] += 1
                  if rtt is not None:
                      totals[target]["rtts"].append(rtt)
              if not ok:
                  consecutive[target] += 1
                  if consecutive[target] >= 2:
                      anomaly(target, "{} consecutive drops".format(consecutive[target]))
                  else:
                      anomaly(target, "packet loss in {}s window".format(WINDOW_SECONDS))
              else:
                  consecutive[target] = 0
                  if rtt is not None and rtt > RTT_THRESHOLD_MS:
                      anomaly(target, "RTT {:.1f}ms > {}ms".format(rtt, RTT_THRESHOLD_MS))

      def ping_worker(target):
          # -i 1 = one probe/second, -O = report timeouts as lines, -D = unix
          # timestamps, -n = no DNS, -q-ish output via -p is not needed: we parse
          # the default reply lines. Runs until `running` flips; ping exits with
          # us when we kill it via the timeout wait loop below.
          cmd = ["/run/wrappers/bin/ping" if os.path.exists("/run/wrappers/bin/ping")
                 else "ping", "-n", "-D", "-O", "-i", "1", target]
          try:
              proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                      stderr=subprocess.STDOUT, text=True)
          except OSError as exc:
              utc, _, _ = timestamps()
              log_line("ANOMALY {} target={} reason=ping-failed-to-start {}".format(utc, target, exc))
              return
          try:
              for line in proc.stdout:
                  if not running:
                      break
                  line = line.strip()
                  m = re.search(r"time[=<]=?([\d.]+)\s*ms", line)
                  if m:
                      record(target, True, float(m.group(1)))
                  elif ("no answer yet" in line or "Destination" in line
                        or "unreachable" in line or "timed out" in line):
                      record(target, False, None)
                  # A timestamped line that is neither a reply nor a timeout is
                  # ignored; genuinely lost probes still surface via -O.
          finally:
              proc.terminate()

      workers = [threading.Thread(target=ping_worker, args=(t,), daemon=True)
                 for t in TARGETS]
      for w in workers:
          w.start()

      next_summary = now_epoch() + SUMMARY_INTERVAL
      next_pressure = now_epoch() + PRESSURE_INTERVAL
      last_p_iface = iface_stats()
      last_p_udp = udp_stats()
      last_p_ts = now_epoch()
      high_pressure_streak = 0
      last_pressure_anomaly = 0.0

      while running:
          time.sleep(1)
          epoch = now_epoch()
          if epoch >= next_pressure:
              next_pressure += PRESSURE_INTERVAL
              cur_i = iface_stats()
              cur_u = udp_stats()
              dt = epoch - last_p_ts
              if cur_i and last_p_iface and cur_u and last_p_udp and dt > 1.0:
                  tx_kbps = (cur_i[2] - last_p_iface[2]) / 1024.0 / dt
                  udp_out_pps = (cur_u[3] - last_p_udp[3]) / dt
                  players = fetch_player_count()
                  if players and players > 0:
                      tx_per_p = tx_kbps / players
                      pps_per_p = udp_out_pps / players
                      if (tx_per_p > TX_PER_PLAYER_KBPS_THRESHOLD
                              or pps_per_p > UDP_OUT_PER_PLAYER_PPS_THRESHOLD):
                          high_pressure_streak += 1
                          if high_pressure_streak >= 2 and (epoch - last_pressure_anomaly) >= 60.0:
                              last_pressure_anomaly = epoch
                              utc, bk, local = timestamps()
                              log_line(
                                  "ANOMALY {} (+07 {}) [{}] target=net-pressure "
                                  "reason=high_tx_per_player players={} tx_kbps={:.1f} "
                                  "tx_per_player_kbps={:.1f} udp_out_pps={:.1f} "
                                  "udp_out_per_player_pps={:.1f}".format(
                                      utc, bk, local, players, tx_kbps, tx_per_p,
                                      udp_out_pps, pps_per_p))
                      else:
                          high_pressure_streak = 0
                  else:
                      high_pressure_streak = 0
              last_p_iface = cur_i
              last_p_udp = cur_u
              last_p_ts = epoch

          if epoch >= next_summary:
              next_summary += SUMMARY_INTERVAL
              utc, bk, local = timestamps()
              rx_d, tx_d, rcv_d, in_d, rx_kbps, tx_kbps, udp_out_pps = counter_deltas()
              parts = []
              for t in TARGETS:
                  tt = totals[t]
                  sent = tt["sent"]
                  recv = tt["recv"]
                  rtts = tt["rtts"]
                  if rtts:
                      stat = "min/avg/max {:.1f}/{:.1f}/{:.1f}ms".format(
                          min(rtts), sum(rtts) / len(rtts), max(rtts))
                  else:
                      stat = "min/avg/max -/-/-"
                  parts.append("{}: sent/recv {}/{} loss {:.1f}% {}".format(
                      t, sent, recv, 100.0 * (sent - recv) / sent if sent else 0.0,
                      stat))
              log_line("SUMMARY {} (+07 {}) [{}] {} | {} rx_kbps={} tx_kbps={} "
                       "udp_out_pps={} rx_drop_delta={} tx_drop_delta={} "
                       "| udp RcvbufErrors_delta={} InErrors_delta={}".format(
                           utc, bk, local, " | ".join(parts), IFACE,
                           "-" if rx_kbps is None else "{:.1f}".format(rx_kbps),
                           "-" if tx_kbps is None else "{:.1f}".format(tx_kbps),
                           "-" if udp_out_pps is None else "{:.1f}".format(udp_out_pps),
                           "-" if rx_d is None else rx_d,
                           "-" if tx_d is None else tx_d,
                           "-" if rcv_d is None else rcv_d,
                           "-" if in_d is None else in_d))
      for w in workers:
          w.join(timeout=3)
    '';
in {
  options.services.wan-probe = {
    enable = lib.mkEnableOption "the read-only continuous WAN connectivity probe";
    targets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["192.168.1.1" "1.1.1.1" "103.10.124.1"];
      description = ''
        Hosts to ping every second, in hop order: local router, ISP edge
        (Cloudflare BKK), and the Valve SG SDR relay.
      '';
    };
    logFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/log/wan-probe.log";
      description = "Probe log file (rotated in place above 10 MB, one .log.1 backup).";
    };
    interface = lib.mkOption {
      type = lib.types.str;
      default = "enp11s0";
      description = "WAN interface whose rx/tx rates and dropped counters are reported.";
    };
    playersUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:5001/players";
      description = "Local mod-server players endpoint used to compute per-player TX rate.";
    };
    txPerPlayerKbpsThreshold = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = "Alert threshold for sustained outbound KB/s per online player.";
    };
    udpOutPerPlayerPpsThreshold = lib.mkOption {
      type = lib.types.int;
      default = 150;
      description = "Alert threshold for sustained outbound UDP packets/s per online player.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.wan-probe = {
      description = "Read-only continuous WAN connectivity probe (3-hop ping monitor)";
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
        # Raw sockets for ping: grant CAP_NET_RAW and drop everything else.
        CapabilityBoundingSet = ["CAP_NET_RAW"];
        AmbientCapabilities = ["CAP_NET_RAW"];
        # Read-only hardening: the only write is the probe's own log file.
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
