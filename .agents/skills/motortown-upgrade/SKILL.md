---
name: motortown-upgrade
description: Upgrading the Motor Town game server (steamcmd) and refreshing external .pak mods per game update
---

# Motor Town Server Upgrade

## When to use
When a Motor Town game update ships (new build on the beta branch) and you must:
- update the game binary via steamcmd, **and**
- refresh external `.pak` mods (which break on every game update).

For pak-only refresh (no game-binary change), see the `mt-mod-update` skill instead.

## Background
- Production game server runs **on host** `asean-mt-server` (NOT a container).
- Game updates run via `motortown-server-update.service` → steamcmd
  `app_update 2223650 -beta beta -betapassword motortowndedi validate`
  (defined in `motortown-server-flake/motortown-server.nix`).
- External `.pak` mods are downloaded at server startup by `mods.nix` from
  `https://www.aseanmotorclub.com/releases/mods/{name}.pak`, served by **amc-peripheral**
  nginx from `/var/lib/mod-releases/mods/`.
- `enableExternalMods` in `flake.nix` (`nixosModules.motortown-server`) maps mod keys → pak filenames.
- `motortown-server` has `restartIfChanged = false` → a deploy applies config **without
  restarting the game** (enables an atomic swap).
- Paks are cooked per game version → **every game update breaks them.**

## Access
| Host | Purpose | Access |
|------|---------|--------|
| asean-mt-server | game host (systemctl) | `root@asean-mt-server` (Tailscale) or `root@192.168.1.163` (LAN) |
| asean-mt-server | state-dir / cache ops | `steam@asean-mt-server` (or `steam@192.168.1.163`) |
| amc-peripheral | pak file server (nginx) | `root@amc-peripheral` (Tailscale) or `root@45.77.171.81` (public IP, when off-tailnet) |

> [!NOTE]
> Without Tailscale: deploy needs `asean-mt-server` to resolve to the LAN IP
> (e.g. `/etc/hosts: 192.168.1.163 asean-mt-server`) so `nixos-rebuild --flake .` resolves the
> `asean-mt-server` config attr. Revert the entry after the deploy.

## Proactive workflow (recommended — no broken intermediate state)

### 1. Obtain new paks
Download compatible `.pak`s for the new game version (Nexus). Paks are often inside zips —
extract first (`unzip -j "<zip>" -d <tmp>`). Paks with no new version must be **disabled**
(removed from `enableExternalMods`) until one exists.

### 2. Upload paks to amc-peripheral
```bash
scp <name>.pak root@amc-peripheral:/var/lib/mod-releases/mods/   # or root@45.77.171.81
curl -sI https://www.aseanmotorclub.com/releases/mods/<name>.pak | head -1   # expect 200
```

### 3. Update flake.nix enableExternalMods
Production: `nixosModules.motortown-server`. Use the pak filename (minus `.pak`) as the quoted
key; remove old-version + disabled keys:
```nix
enableExternalMods = {
  "MajasDetailWorksV3.3-7.19-SERVER_P" = true;
  "MajasMnTrailerworksV7-7.19_P" = true;
};
```
Quote keys with dashes/dots/pluses. Run `alejandra .` (deploy pre-check requires formatted Nix).

### 4. Isolate uncommitted submodule dirt
`deploy --override-input motortown-server ./motortown-server-flake` ships the working tree.
Stash first if you don't want uncommitted submodule work deployed:
```bash
git -C motortown-server-flake stash
```

### 5. Deploy config (no game restart)
```bash
nix develop --command deploy root@asean-mt-server   # --skip-pytest if no backend changes
```
Verify config + that the game was NOT restarted:
```bash
nix eval .#nixosConfigurations.asean-mt-server.config.services.motortown-server.enableExternalMods
ssh root@asean-mt-server "systemctl show motortown-server -p ActiveEnterTimestamp --value"
```

### 6. Purge pak cache (if same-name paks were overwritten)
New-named paks download fresh; same-name paks reuse stale cache → purge to force re-download:
```bash
ssh steam@asean-mt-server "rm -rf /var/lib/motortown-server/.mod-cache/paks/"
```

### 7. Run the game update (atomic)
```bash
# The update trigger is the motortown-server preStart gate: it runs steamcmd
# `app_update ... validate` only when DedicatedServerConfig.json is ABSENT.
# Remove it, then restart — preStart does steamcmd update + (new) pak install + boot.
ssh root@asean-mt-server "rm -f /var/lib/motortown-server/DedicatedServerConfig.json"
ssh root@asean-mt-server "systemctl restart --no-block motortown-server.service"
ssh root@asean-mt-server "journalctl -u motortown-server -f"
```
The restart re-runs preStart: steamcmd `app_update 2223650 -beta beta ... validate`, then
`mods.nix` deletes all non-base paks and installs the enabled ones, then the game boots.
Success marker in the journal: `Success! App '2223650' fully installed`.

> [!WARNING]
> Do **not** use `systemctl start motortown-server-update.service` — that unit runs as
> `User=steam` but calls `systemctl stop/start motortown-server`, which fails with
> "Interactive authentication required" (steam lacks those privileges). The preStart-gate
> method above is the working update path.

### 8. Verify
```bash
# game build advanced
ssh root@asean-mt-server "grep -i '\"buildid\"' /var/lib/motortown-server/steamapps/appmanifest_2223650.acf | head -1"
# server active
ssh root@asean-mt-server "systemctl is-active motortown-server"
# paks load cleanly (expect NO mismatch/cooked/failed lines)
ssh root@asean-mt-server "journalctl -u motortown-server --since '5 min ago' --no-pager | grep -iE 'pak|mismatch|cooked|failed to load'"
# installed paks == enableExternalMods (disabled mods are auto-removed from Content/Paks)
ssh root@asean-mt-server "ls /var/lib/motortown-server/MotorTown/Content/Paks/ | grep -i '_P.pak'"
# MTDediMod server mod loaded + serving (probe a real route; 200 + JSON == healthy)
ssh root@asean-mt-server "curl -s http://localhost:5001/players | head -c 120"
ssh root@asean-mt-server "tail -n 80 /var/lib/motortown-server/MotorTown/Binaries/Win64/ue4ss/UE4SS.log | grep -iE 'MotorTownMods|LuaHttpServer|ERROR|FATAL' | tail -5"
# native game API
ssh root@asean-mt-server "curl -s 'http://localhost:8080/player/list?password=' | head -c 120"
```

## Quick game-only update (no pak changes)
Rare (paks usually break too). Same preStart-gate trigger — removing the config forces a
steamcmd `app_update validate` on the next restart even if no paks changed. Pick a low-player
window (the restart still drops players):
```bash
ssh root@asean-mt-server "rm -f /var/lib/motortown-server/DedicatedServerConfig.json && systemctl restart motortown-server.service"
```

## Failure modes
- **MTDediMod server mod breaks**: not reinstalled on a game update (version marker matches), so
  old C++ hooks run on the new game. If `UE4SS.log` shows load errors → rebuild via `mtdedimod-deploy`.
- **steamcmd Steam Guard / login failure**: preStart's steamcmd errors → `motortown-server`
  fails to activate (systemd `Restart=always` retries, but it'll keep failing). Check
  `/run/agenix/steam` + `journalctl -u motortown-server` for the steamcmd login error.
- **Daily restart timer race**: `motortown-server-restart.service` fires `*-*-* 08:30` — avoid
  running the update near then.
- **No game-binary rollback**: game files aren't NixOS-generation versioned. Repair via
  `validate`, or revert `enableExternalMods` + redeploy for paks.

## Related skills
- `mt-mod-update` — pak-only refresh (no game-binary change).
- `mtdedimod-deploy` — rebuild the UE4SS server mod when a game update breaks it.
- `server-access` — SSH / service access to AMC servers.
