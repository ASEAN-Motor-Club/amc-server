# nginx built from a pinned upstream tarball.
#
# Both nginx branches in nixpkgs (stable 1.30.6, mainline 1.31.8 — checked
# 2026-11-19) predate F5's 2026-11-18 security release, so they are still
# vulnerable to CVE-2026-123633 (HTTP/2 use-after-free, RCE) and
# CVE-2026-123007 (HTTP/2 flow-control memory corruption, RCE). Both are fixed
# in 1.30.7 / 1.31.9.
#
# Instead of waiting for the nixpkgs bump, take the unstable nginxStable recipe
# (its patches and configure flags match the 1.30 series; the 25.05 recipe's
# zlib-ng patch does not apply to 1.30.7) and point its src at the 1.30.7
# release tarball. Verified to build with the ngx_brotli module.
#
# Drop this module and go back to `pkgs.nginxStable` once the pinned nixpkgs
# ships >= 1.30.7.
{
  pkgs,
  nixpkgs-unstable,
  ...
}: let
  unstable = nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in {
  services.nginx.package =
    (unstable.nginxStable.override {
      # ngx_brotli, so precompressed .br static files can be served
      # (brotli_static) alongside gzip_static.
      modules = [unstable.nginxModules.brotli];
    }).overrideAttrs (_: {
      version = "1.30.7";
      nginxVersion = "1.30.7";
      src = pkgs.fetchurl {
        url = "https://nginx.org/download/nginx-1.30.7.tar.gz";
        hash = "sha256-JWW1yDcFDpWPcPsPc8SOK8pFQq00n9NW9G+wxyYQvG4=";
      };
    });
}
