{
  lib,
  pkgs,
  config,
  ...
}:
with lib; let
  cfg = config.services.beammp-server-logger;
in {
  options.services.beammp-server-logger = {
    enable = lib.mkEnableOption "BeamMP server log streaming";
    serverLogsPath = mkOption {
      type = types.str;
      description = "Path to Server.log (or glob pattern)";
    };
    relpServerHost = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "RELP server host";
    };
    relpServerPort = mkOption {
      type = types.int;
      default = 2514;
      description = "RELP server port";
    };
    tag = mkOption {
      type = types.str;
      default = "beammp";
      description = "Tag for log lines";
    };
  };

  config = mkIf cfg.enable {
    services.rsyslogd.extraConfig = ''
      input(type="imfile"
        File="${cfg.serverLogsPath}"
        Tag="${cfg.tag}"
        ruleset="mt-out"
        addMetadata="on"
      )
    '';
  };
}
