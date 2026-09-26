# Guest bootstrap (Motor Town dedi on Windows Server 2022, KVM)

Idempotent provisioning for the `motortown-win` KVM guest. Source of truth
for the guest environment; VM snapshots are only a fast-start cache.

## What bootstrap.ps1 converges (check-then-apply per item)

1. VC++ 2015-2022 x64 redist (>= 14.44.35211 — the UE4SS native-load fix)
2. Firewall rules: UDP 7777/7778/27015/27016, TCP 8080 + 5000/5001, exe rule
3. Steam client + `SteamClientService` (the thing that gives `Steam: Y`)
4. steamcmd + `update_mt.bat` (club creds from host agenix, pushed via WinRM
   base64 — never over the plain-HTTP route); installs the dedi via
   `+app_update 2223650 -beta beta -betapassword <from host secrets> validate`
   when the exe is missing
5. Vector 0.46.1 + `VectorLogs` service (installed, auto, STARTED)
6. Byte-exact `GameUserSettings.ini` from base64 (hash-compared)
7. `start-dedi.cmd`
8. 16 GB pagefile (corrects size drift too)
9. `DediStart` (S4U) + `MTDediWatchdog` tasks — the watchdog is inert unless
   `C:\mtserver\DEDI_ENABLED` exists, and relaunches via the S4U DediStart
   task so the dedi keeps `Steam: Y`
10. Mods/UE4SS: `.installed-mod-version` marker checked against
    `mod-versions.nix`; with a staged zip (see below) it installs `ue4ss/`,
    `version.dll`, `UE4SS_Signatures`, the `*_SERVER_P.pak`, and writes the
    marker

## Files

- `bootstrap.ps1` — idempotent PowerShell, safe to re-run
- `provision_guest.py` — one command from a machine with ssh to the host
- `GameUserSettings.ini.b64` — byte-exact server config captured from prod
  (contains the `★★` name; base64 because WinRM mangles non-ASCII)
- `start-dedi.cmd`, `vector.toml`, `DediStart-task.xml`,
  `MTDediWatchdog-task.xml`, `watchdog.ps1` — current-good artifacts

## Usage

    MTGUEST_PW=... python3 provision_guest.py [guest-ip]   # default 192.168.122.61

Password resolution: `MTGUEST_PW` env, else `/root/.mtguest-pw` on the host
(chmod 600). No other fallback.

Optional:

    MOD_ZIP=/path/MotorTownMods_server-vX.zip          # stage a mod build
    MOD_SIG_DIR=/path/UE4SS_Signatures                 # stage signatures

## Not covered here (deliberate)

- The unattended Windows install itself (autounattend ISO) — one-time
  bootstrap, replay documented in the ops skill
- Start/stop of the dedi: provisioning is state-only; lifecycle stays an
  operator action (arm/disarm via `DEDI_ENABLED`)
