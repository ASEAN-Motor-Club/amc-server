---
name: mt-mod-update
description: Refreshing Motor Town external .pak mods (per game update or new mod versions)
---

# Update Motor Town External Mods (.pak)

## When to use
When external `.pak` mods need refreshing — a game update broke them, or mod authors released
new versions. For the full game-binary (steamcmd) + pak upgrade, see the `motortown-upgrade` skill.

## Scope
**Pak-only** refresh. The game binary itself is updated separately via steamcmd
(`motortown-upgrade`). Use this skill when only paks change.

## Pak hosting
- amc-peripheral nginx serves `https://www.aseanmotorclub.com/releases/mods/{name}.pak` from
  `/var/lib/mod-releases/mods/`.
- The game server runs **on host** `asean-mt-server` (not a container) and downloads paks at
  startup via `mods.nix`; the pak filename (without `.pak`) is the `enableExternalMods` key.

## Access
| Host | Purpose | Access |
|------|---------|--------|
| amc-peripheral | pak upload (nginx) | `root@amc-peripheral` (Tailscale) or `root@45.77.171.81` (public IP, off-tailnet) |
| asean-mt-server | cache purge / restart | `steam@asean-mt-server` (file ops) / `root@asean-mt-server` (systemctl); LAN: `192.168.1.163` |

## Steps

### 1. Extract + identify pak filenames
New paks are often inside zips (Nexus downloads). Extract and note the exact filenames:
```bash
unzip -j "<downloaded>.zip" -d <tmp>     # -j flattens paths; some zips use a Paks/ subdir
ls <tmp>
```
The filename (without `.pak`) becomes the mod key.

### 2. Upload to amc-peripheral
```bash
scp <name>.pak root@amc-peripheral:/var/lib/mod-releases/mods/   # or root@45.77.171.81
curl -sI https://www.aseanmotorclub.com/releases/mods/<name>.pak | head -1   # expect HTTP 200
```

> [!IMPORTANT]
> Upload to **amc-peripheral**, not the game host. The game server downloads paks from the web
> URL served by amc-peripheral's nginx at `aseanmotorclub.com/releases/mods/`.

### 3. Update enableExternalMods in flake.nix
Production: `nixosModules.motortown-server` → `enableExternalMods`. Use the pak filename (minus
`.pak`) as the key; quote names with dashes/dots/pluses; remove old-version keys:
```nix
enableExternalMods = {
  "MajasDetailWorksV3.3-7.19-SERVER_P" = true;
  "MajasMnTrailerworksV7-7.19_P" = true;
};
```
Run `alejandra .` (the deploy pre-check fails on unformatted Nix).

### 4. Deploy (no game restart — restartIfChanged = false)
```bash
nix develop --command deploy root@asean-mt-server
```

### 5. Purge pak cache if same-name paks were overwritten
New-named paks download fresh automatically. Same-name paks (content changed, name unchanged)
reuse stale cache → purge to force re-download, then restart so preStart re-pulls them:
```bash
ssh steam@asean-mt-server "rm -rf /var/lib/motortown-server/.mod-cache/paks/"
ssh root@asean-mt-server "systemctl restart motortown-server"
```

### 6. Verify
```bash
ssh root@asean-mt-server "journalctl -u motortown-server --since '5 min ago' --no-pager | grep -iE 'Downloading external mod|pak|mismatch|cooked|failed'"
ssh root@asean-mt-server "ls /var/lib/motortown-server/MotorTown/Content/Paks/ | grep -i '_P.pak'"
```
`mods.nix` deletes all non-base paks then reinstalls only the enabled ones, so disabled mods'
paks are removed automatically. A 404 on a mod means its pak isn't uploaded to amc-peripheral.

## Old pak cleanup
Remove obsolete paks from amc-peripheral when no longer referenced:
```bash
ssh root@amc-peripheral "rm /var/lib/mod-releases/mods/<old-name>.pak"
```

## Related skills
- `motortown-upgrade` — full game-binary (steamcmd) + pak upgrade.
- `mtdedimod-deploy` — UE4SS server mod rebuild.
- `server-access` — SSH / service access to AMC servers.
