# Report-only GameThread freeze probe for the Motor Town dedicated server.
#
# Motivation: recurring mass-logout events look like the MT GameThread going
# unresponsive while the HTTP mod-server API on :5001 keeps its listener open —
# a curl to /status/general then hangs until timeout instead of failing fast.
# This service polls that endpoint and, ONLY on a timeout (curl exit 28, i.e.
# the server is up but answering too slowly), appends a structured diagnostic
# snapshot to /var/log/motortown-hang-probe.log for later correlation with the
# mass-logout timeline. Exit 7 (connection refused — server stopped/booting)
# is deliberately NOT a trigger.
#
# STRICTLY READ-ONLY: the script never signals, kills or restarts anything.
{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.services.motortown-hang-probe;
  probeScript = pkgs.writeShellScript "motortown-hang-probe.sh" ''
    set -u

    URL="${cfg.statusUrl}"
    LOG="${cfg.logFile}"
    MAX_LOG_BYTES=$((10 * 1024 * 1024))  # rotate above 10 MB
    POLL_INTERVAL=5                      # seconds between polls
    MIN_SNAPSHOT_GAP=15                  # at most 1 snapshot / 15 s per hang
    MT_LOG="/var/lib/motortown-server/MotorTown/Binaries/Win64/ue4ss/UE4SS.log"
    SRV_LOG="/var/lib/motortown-server/MotorTown/Saved/ServerLog/motortown.log"

    last_snapshot=0  # epoch of the last snapshot; 0 = armed (snapshot next timeout)

    read_file() {
      # Print a file's contents with a header; missing files are fine.
      if [ -r "$1" ]; then
        echo "--- $1 ---"
        cat "$1" 2>/dev/null
      else
        echo "--- $1 --- (missing or unreadable)"
      fi
    }

    tail_file() {
      # Last N lines of a file with a header; missing files are fine.
      n="$1"
      f="$2"
      if [ -r "$f" ]; then
        echo "--- last $n lines of $f ---"
        tail -n "$n" "$f" 2>/dev/null
      else
        echo "--- last $n lines of $f --- (missing or unreadable)"
      fi
    }

    snapshot() {
      # Find the Motor Town server PID (read-only: never signals anything).
      mt_pid="$(pgrep -f 'MotorTownServer-Win64-Shipping.exe' | head -n 1 || true)"
      if [ -z "''${mt_pid:-}" ] || [ ! -d "/proc/$mt_pid" ]; then
        echo "=== probe: timeout on $URL but no MotorTownServer PID found ===" >> "$LOG"
        return 0
      fi

      # GameThread TID: exact comm match first; fallback = highest CPU time.
      gt_tid=""
      gt_src="highest-CPU fallback"
      for tid in /proc/"$mt_pid"/task/*; do
        comm="$(cat "$tid/comm" 2>/dev/null || true)"
        if [ "$comm" = "GameThread" ]; then
          gt_tid="$(basename "$tid")"
          gt_src="exact GameThread match"
          break
        fi
      done
      if [ -z "$gt_tid" ]; then
        # Fallback: highest utime+stime (fields 12+13) among the process's tasks.
        best_cpu="-1"
        for tid in /proc/"$mt_pid"/task/*; do
          stat_line="$(cat "$tid/stat" 2>/dev/null || true)"
          # comm may contain spaces/parens — cut everything up to the last ')'.
          rest="''${stat_line##*) }"
          utime="$(echo "$rest" | awk '{print $12}')"
          stime="$(echo "$rest" | awk '{print $13}')"
          cpu="$((utime + stime))"
          if [ "$cpu" -gt "$best_cpu" ]; then
            best_cpu="$cpu"
            gt_tid="$(basename "$tid")"
          fi
        done
        # Absolute tie (all-zero CPU): just take the first task.
        if [ -z "$gt_tid" ]; then
          gt_tid="$(basename "$(echo /proc/"$mt_pid"/task/* | awk '{print $1}')")"
        fi
      fi

      # wineserver PID for the Proton/Wine instance hosting the game.
      wine_pid="$(pgrep -x wineserver | head -n 1 || true)"

      utc_ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      local_ts="$(TZ=Asia/Bangkok date '+%Y-%m-%d %H:%M:%S %z')"

      {
        echo "==================================================================="
        echo "=== GameThread hang snapshot $utc_ts (local: $local_ts)"
        echo "=== trigger: curl $URL timed out (exit 28)"
        if [ -n "$gt_tid" ] || [ -n "$wine_pid" ]; then
          echo "=== mt_pid=$mt_pid tid=''${gt_tid:-<none>} wineserver=''${wine_pid:-<none>} ($gt_src)"
        fi

        echo "### process state"
        if [ -n "$gt_tid" ]; then
          st="/proc/$mt_pid/task/$gt_tid/status"
          if [ -r "$st" ]; then
            grep -E '^(State|VmRSS|voluntary_ctxt_switches|nonvoluntary_ctxt_switches)' "$st"
          else
            echo "(status unreadable: $st)"
          fi
          echo "wchan: $(cat /proc/"$mt_pid"/task/"$gt_tid"/wchan 2>/dev/null || echo '?')"
          echo "kernel stack:"
          cat /proc/"$mt_pid"/task/"$gt_tid"/stack 2>/dev/null || echo "(stack unreadable)"
        fi
        echo "fd count: $(ls /proc/"$mt_pid"/fd 2>/dev/null | wc -l)"

        echo "### wineserver"
        if [ -n "$wine_pid" ]; then
          echo "pid=$wine_pid wchan: $(cat /proc/"$wine_pid"/wchan 2>/dev/null || echo '?')"
          echo "kernel stack:"
          cat /proc/"$wine_pid"/stack 2>/dev/null || echo "(stack unreadable)"
        else
          echo "(no wineserver process found)"
        fi

        echo "### pressure stall info"
        read_file /proc/pressure/cpu
        read_file /proc/pressure/memory
        read_file /proc/pressure/io

        echo "### recent game logs"
        tail_file 15 "$MT_LOG"
        tail_file 15 "$SRV_LOG"
      } >> "$LOG" 2>/dev/null
    }

    while true; do
      curl -sf --max-time 6 -o /dev/null "$URL"
      rc=$?
      now="$(date +%s)"

      if [ "$rc" -eq 28 ]; then
        # Timeout: server listening but not answering. Snapshot at most once
        # per 15 s while the hang persists; the first timeout of a hang
        # (last_snapshot == 0) always snapshots.
        if [ "$last_snapshot" -eq 0 ] || [ $((now - last_snapshot)) -ge "$MIN_SNAPSHOT_GAP" ]; then
          snapshot
          last_snapshot="$now"
        fi
      elif [ "$rc" -eq 7 ] || [ "$rc" -eq 0 ]; then
        # Refused (stopped/booting) or healthy: re-arm so the next genuine
        # hang snapshots immediately.
        last_snapshot=0
      fi

      # Rotate the log when it grows past MAX_LOG_BYTES (keep one generation).
      if [ -f "$LOG" ]; then
        size="$(stat -c %s "$LOG" 2>/dev/null || echo 0)"
        if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
          mv -f "$LOG" "$LOG.1" 2>/dev/null || true
          : > "$LOG"
        fi
      fi

      sleep "$POLL_INTERVAL"
    done
  '';
in {
  options.services.motortown-hang-probe = {
    enable = lib.mkEnableOption "the read-only Motor Town GameThread freeze probe";
    statusUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:5001/status/general";
      description = "HTTP endpoint polled to detect a GameThread freeze.";
    };
    logFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/log/motortown-hang-probe.log";
      description = "Snapshot log file (rotated in place above 10 MB).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.motortown-hang-probe = {
      description = "Read-only Motor Town GameThread freeze probe (log-only)";
      documentation = ["https://github.com/ASEAN-Motor-Club/amc-server"];
      wantedBy = ["multi-user.target"];
      after = ["network.target"];
      # Long-running poller, not an oneshot.
      path = with pkgs; [curl procps gawk coreutils gnugrep];
      serviceConfig = {
        Type = "simple";
        ExecStart = probeScript;
        Restart = "always";
        RestartSec = 5;
        # Read-only hardening: the only writes are the probe's own log files.
        ProtectSystem = "full";
        ReadWritePaths = ["/var/log"];
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        # Reading another user's /proc/<pid>/stack & friends needs ptrace
        # permission; the game runs as "steam", so keep CAP_SYS_PTRACE and
        # drop everything else.
        CapabilityBoundingSet = ["CAP_SYS_PTRACE"];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
      };
      environment.TZ = "Asia/Bangkok";
    };
  };
}
