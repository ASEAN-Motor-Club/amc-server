# Headless Unreal Engine 5 commandlets (Epic prebuilt Linux binaries).
#
# There is no Unreal Engine package in nixpkgs: Epic's source tree is behind an
# account-gated GitHub repo and the EULA forbids redistributable builds, so no
# derivation can fetch it. The only supported path is Epic's own prebuilt
# `Linux_Unreal_Engine_<version>.zip`, downloaded by a human with an Epic Games
# account.
#
# Epic's binaries are linked against an Ubuntu-style FHS layout, so they cannot
# run directly on NixOS. This module wraps an extracted engine tree (which stays
# OUTSIDE the nix store — it is tens of GB and must not be garbage collected)
# in a `buildFHSEnv` and exposes the headless entry points on PATH.
#
# Everything here is GPU-free: `UnrealPak`, `UnrealEditor-Cmd -run=<commandlet>`
# and UAT cooking do not need a display or a hardware Vulkan device. Running the
# full editor GUI is NOT supported on a host without a real GPU.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.amc.unrealEngine;
  inherit (lib) mkEnableOption mkIf mkOption types;

  engineRoot = cfg.enginePath;
  linuxBinaries = "${engineRoot}/Engine/Binaries/Linux";

  # Superset of what UE5's Linux binaries link against. SDL2/X11/GL/Vulkan are
  # required even for -Cmd runs because the shared editor library links them.
  unrealLibs = p:
    with p;
    with p.xorg; [
      bash
      coreutils
      alsa-lib
      libpulseaudio
      SDL2
      zlib
      openssl
      icu
      expat
      dbus
      glib
      nss
      nspr
      libuuid
      numactl
      freetype
      fontconfig
      libGL
      libglvnd
      vulkan-loader
      libdrm
      libxkbcommon
      libxcb
      libxshmfence
      libX11
      libXcursor
      libXdamage
      libXext
      libXfixes
      libXinerama
      libXrandr
      libXrender
      libXScrnSaver
      libXcomposite
      libXi
      libXtst
      libSM
      libICE
      pango
      cairo
      atk
      gtk3
      p.stdenv.cc.cc.lib
    ];

  unrealFhs = pkgs.buildFHSEnv {
    name = "unreal-fhs";
    targetPkgs = unrealLibs;
    # The FHS init runs `exec <runScript> "$@"`; an empty runScript makes it
    # `exec "$@"`, i.e. run the engine binary we pass as the first argument.
    runScript = "";
    profile = ''
      export UE_ENGINE_ROOT="${engineRoot}"
    '';
  };

  # The FHS wrapper runs whatever command it is given (runScript is empty), so
  # pass the engine binary as the first argument and everything else through.
  #
  # UnrealEditor-Cmd refuses to start as root ("Refusing to run with the root
  # privileges"), so when invoked as root we drop to the service user, which
  # owns the engine tree (UE writes logs/config into Engine/**/Saved).
  mkUeCmd = name: relativePath:
    pkgs.writeShellScriptBin name ''
      bin="${linuxBinaries}/${relativePath}"
      if [ ! -x "$bin" ]; then
        echo "${name}: missing $bin" >&2
        echo "Extract Epic's Linux_Unreal_Engine zip into ${engineRoot} first, then:" >&2
        echo "  chown -R ${cfg.user}:${cfg.group} ${engineRoot}" >&2
        exit 127
      fi
      if [ "$(id -u)" -eq 0 ] && [ "${cfg.user}" != "root" ]; then
        exec ${pkgs.util-linux}/bin/runuser -u ${cfg.user} -- \
          env HOME=${cfg.homeDir} ${unrealFhs}/bin/unreal-fhs "$bin" "$@"
      fi
      exec ${unrealFhs}/bin/unreal-fhs "$bin" "$@"
    '';
in {
  options.amc.unrealEngine = {
    enable = mkEnableOption "headless Unreal Engine 5 commandlets (Epic prebuilt binaries)";

    enginePath = mkOption {
      type = types.str;
      default = "/var/lib/unreal-engine";
      description = ''
        Root of the extracted `Linux_Unreal_Engine_<version>` archive, i.e. the
        directory that contains `Engine/`. Kept outside the nix store on
        purpose: the tree is tens of GB and must survive garbage collection.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "unreal";
      description = ''
        Account that owns the engine tree and runs the commandlets.
        UnrealEditor-Cmd refuses to start as root, so invocations as root are
        dropped to this user. Set to `"root"` to disable the privilege drop.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "unreal";
      description = "Group for {option}`user`.";
    };

    homeDir = mkOption {
      type = types.str;
      default = "/var/lib/unreal-engine-home";
      description = ''
        Home directory for {option}`user`. UE writes config, logs and the local
        derived-data cache under `$HOME`, and the engine tree must stay
        readable by this account.
      '';
    };
  };

  config = mkIf cfg.enable {
    users.groups = lib.mkIf (cfg.group != "root") {
      ${cfg.group} = {};
    };

    users.users = lib.mkIf (cfg.user != "root") {
      ${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.homeDir;
        createHome = true;
        description = "Unreal Engine headless commandlets";
      };
    };

    # Create the engine mount point and the commandlet home. Extraction itself
    # is a manual, human step (it needs the account-gated Epic download).
    systemd.tmpfiles.rules = [
      "d ${engineRoot} 0755 ${cfg.user} ${cfg.group} -"
      "d ${cfg.homeDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.homeDir}/.cache 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.homeDir}/.config 0750 ${cfg.user} ${cfg.group} -"
    ];

    environment.systemPackages = [
      (mkUeCmd "unrealpak" "UnrealPak")
      (mkUeCmd "unreal-editor-cmd" "UnrealEditor-Cmd")
      unrealFhs
    ];

    environment.variables.UE_ENGINE_ROOT = engineRoot;
  };
}
