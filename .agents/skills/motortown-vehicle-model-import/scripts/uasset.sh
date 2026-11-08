#!/usr/bin/env bash
# Run the mt-pak-extract UAssetTool without inline env on the command line.
#   bash scripts/uasset.sh --dump /abs/asset.uasset
#   bash scripts/uasset.sh --patch-named-exports cfg.json template.uasset outdir/
#
# Notes this encodes:
#  * DOTNET_ROOT must be <sdk>/share/dotnet (apphost looks for host/fxr under it)
#  * invoking the .dll through `dotnet` skips the apphost's native-lib lookup
#  * store paths get GC'd, so resolve the SDK at run time instead of hardcoding a hash
set -uo pipefail
REPO=${MT_REPO:-/opt/data/workspace/amc-server/mt-pak-extract-wt-0719}
DLL="$REPO/csharp/UAssetTool/bin/Release/net8.0/UAssetTool.dll"

SDK=${DOTNET_SDK:-}
if [ -z "$SDK" ]; then
  for cand in $(ls -d /nix/store/*dotnet-sdk-8* 2>/dev/null | grep -v '\.drv$'); do
    if [ -d "$cand/share/dotnet/host/fxr" ]; then SDK=$cand; break; fi
  done
fi
if [ -z "$SDK" ] || [ ! -x "$SDK/bin/dotnet" ]; then
  echo "no usable dotnet SDK (need share/dotnet/host/fxr); set DOTNET_SDK=" >&2
  exit 1
fi
if [ ! -f "$DLL" ]; then
  echo "UAssetTool not built at $DLL — build with scripts/build_uassettool_0719.sh first" >&2
  exit 1
fi

cd "$REPO" || exit 1
exec "$SDK/bin/dotnet" "$DLL" "$@"
