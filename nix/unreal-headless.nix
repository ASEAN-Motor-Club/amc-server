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
  mkUeCmd = name: relativePath:
    pkgs.writeShellScriptBin name ''
      if [ ! -x "${linuxBinaries}/${relativePath}" ]; then
        echo "${name}: missing ${linuxBinaries}/${relativePath}" >&2
        echo "Extract Epic's Linux_Unreal_Engine zip into ${engineRoot} first." >&2
        exit 127
      fi
      exec ${unrealFhs}/bin/unreal-fhs "${linuxBinaries}/${relativePath}" "$@"
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
  };

  config = mkIf cfg.enable {
    # Create the mount point for the extracted engine. Extraction itself is a
    # manual, human step (see the AMC docs) because it needs the Epic download.
    systemd.tmpfiles.rules = [
      "d ${engineRoot} 0755 root root -"
    ];

    environment.systemPackages = [
      (mkUeCmd "unrealpak" "UnrealPak")
      (mkUeCmd "unreal-editor-cmd" "UnrealEditor-Cmd")
      unrealFhs
    ];

    environment.variables.UE_ENGINE_ROOT = engineRoot;
  };
}
