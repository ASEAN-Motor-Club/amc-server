{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.beamcomp-discord;

  bridge = pkgs.writeShellApplication {
    name = "beamcomp-discord";
    runtimeInputs = [
      pkgs.python3
      pkgs.systemd # journalctl
    ];
    text = ''
      exec python3 ${./beamcomp-discord}/bridge.py "$@"
    '';
  };
in
{
  options.services.beamcomp-discord = {
    enable = lib.mkEnableOption "BeamComp race events to Discord";

    channelId = lib.mkOption {
      type = lib.types.str;
      description = "Discord channel Snowflake to post race activity into";
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = "Bot token file; the service gets it via LoadCredential";
    };

    runLog = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/beammp-server/Resources/Server/BeamComp/beamcomp.runs.jsonl";
      description = "BeamComp append-only run log to tail";
    };

    unit = lib.mkOption {
      type = lib.types.str;
      default = "beammp-server";
      description = "systemd unit whose journal carries the BeamComp events";
    };
  };

  config = lib.mkIf cfg.enable {
    # BeamComp only writes beamcomp.runs.jsonl while enableStatistics is on.
    # The config file is a preserved state file (seeded with cp -n by the
    # BeamMP module), so add the key only when it is absent -- club edits such
    # as grids, presets and the race password must survive untouched.
    systemd.services.beammp-server.preStart = lib.mkAfter ''
      beamcomp_ini=Resources/Server/BeamComp/beamcomp.config.ini
      if [ -f "$beamcomp_ini" ] && ! grep -q '^enableStatistics' "$beamcomp_ini"; then
        printf '\nenableStatistics = true\n' >> "$beamcomp_ini"
      fi
    '';

    systemd.services.beamcomp-discord = {
      description = "BeamComp race events to Discord";
      after = [ "beammp-server.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${bridge}/bin/beamcomp-discord";
        StateDirectory = "beamcomp-discord";
        DynamicUser = true;
        SupplementaryGroups = [ "systemd-journal" ];
        LoadCredential = [ "discord-token:${cfg.tokenFile}" ];

        Environment = [
          "BEAMCOMP_CHANNEL_ID=${cfg.channelId}"
          "BEAMCOMP_RUNLOG=${cfg.runLog}"
          "BEAMCOMP_STATE_DIR=/var/lib/beamcomp-discord"
          "BEAMCOMP_UNIT=${cfg.unit}"
        ];

        # Hardening: the bridge only needs to read one directory and talk out.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;

        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
