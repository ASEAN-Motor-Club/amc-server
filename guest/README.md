# Guest bootstrap (Motor Town dedi on Windows Server 2022, KVM)

Idempotent provisioning for the `motortown-win` KVM guest. Source of truth
for the guest environment; VM snapshots are only a fast-start cache.

Files:
- `bootstrap.ps1` — idempotent PowerShell, safe to re-run; converges the
  guest to the declared state
- `provision_guest.py` — runs on any machine with SSH+pywinrm access to the
  host; pushes and executes `bootstrap.ps1` in the guest (base64 route,
  no here-strings, so unicode survives)
- `GameUserSettings.ini.b64` — byte-exact server config captured from prod
  (contains the `★★` name; base64 because WinRM mangles non-ASCII)
- `start-dedi.cmd`, `vector.toml`, `DediStart-task.xml` — current-good
  artifacts the bootstrap deploys

Usage (from a machine that can ssh root@asean-mt-server):

    python3 provision_guest.py <guest-ip>

Password comes from `MTGUEST_PW` env (never hardcoded).
