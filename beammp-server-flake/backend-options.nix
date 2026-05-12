{
  lib,
  config,
  ...
}:
with lib; let
  cfg = config;
  backendOptions = {
    enable = mkEnableOption "BeamMP dedicated server";
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the required port (TCP+UDP) for the game server";
    };
    port = mkOption {
      type = types.port;
      default = 30814;
      description = "Server port (TCP+UDP, single port for both)";
    };
    name = mkOption {
      type = types.str;
      default = "BeamMP Server";
      description = "Server name shown in the server list";
    };
    description = mkOption {
      type = types.str;
      default = "";
      description = "Server description shown in the server list";
    };
    tags = mkOption {
      type = types.str;
      default = "Freeroam";
      description = "Comma-separated server tags";
    };
    maxPlayers = mkOption {
      type = types.ints.positive;
      default = 10;
      description = "Maximum number of players";
    };
    maxCars = mkOption {
      type = types.ints.positive;
      default = 2;
      description = "Maximum cars per player";
    };
    map = mkOption {
      type = types.str;
      default = "/levels/gridmap_v2/info.json";
      description = "Default map path";
    };
    isPrivate = mkOption {
      type = types.bool;
      default = true;
      description = "Hide from the public server list";
    };
    allowGuests = mkOption {
      type = types.bool;
      default = false;
      description = "Allow guest (non-authenticated) players";
    };
    logChat = mkOption {
      type = types.bool;
      default = false;
      description = "Log chat messages to Server.log";
    };
    debug = mkOption {
      type = types.bool;
      default = false;
      description = "Enable verbose debug logging";
    };
    authKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to file containing the BeamMP auth key (from keymaster.beammp.com)";
    };
    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Extra lines appended to ServerConfig.toml [General] section";
    };
    environment = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Extra environment variables for the server process";
    };
    user = mkOption {
      type = types.str;
      default = "beammp";
      description = "OS user for the service";
    };
    group = mkOption {
      type = types.str;
      default = "beammp";
      description = "OS group for the service";
    };
    stateDirectory = mkOption {
      type = types.str;
      default = "beammp-server";
      description = "State directory name (under /var/lib)";
    };
    enableLogStreaming = mkEnableOption "rsyslog log forwarding";
    logsTag = mkOption {
      type = types.str;
      default = "beammp";
      description = "Tag for forwarded log lines";
    };
    relpServerHost = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "RELP target host";
    };
    relpServerPort = mkOption {
      type = types.int;
      default = 2514;
      description = "RELP target port";
    };
    restartSchedule = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "systemd OnCalendar restart schedule (null to disable)";
    };
    serverVersion = mkOption {
      type = types.str;
      default = "v3.9.2";
      description = "BeamMP-Server version to install";
    };
    discordWebhookEnvironmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Env file with DISCORD_ERRORS_WEBHOOK for crash notifications";
    };
    cpuAffinity = mkOption {
      type = types.str;
      default = "4 5";
      description = "CPU cores to pin to (must NOT overlap Motor Town's 0-3)";
    };
    memoryMax = mkOption {
      type = types.str;
      default = "512M";
      description = "Hard memory cap (systemd unit syntax)";
    };
    cpuQuota = mkOption {
      type = types.str;
      default = "200%";
      description = "CPU quota cap (200% = 2 full cores)";
    };
  };
in {
  options = backendOptions;
}
