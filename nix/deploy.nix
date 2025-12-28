{pkgs}:
pkgs.writeShellScriptBin "deploy" ''
  set -xe

  ${pkgs.nixos-rebuild}/bin/nixos-rebuild --target-host "$1" --build-host "$1" --flake . --fast switch \
  --override-input amc-backend ./amc-backend \
  --override-input amc-peripheral ./amc-peripheral \
  --override-input motortown-server ./motortown-server-flake
''
