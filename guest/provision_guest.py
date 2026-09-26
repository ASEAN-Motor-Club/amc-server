#!/usr/bin/env python3
"""Push and execute bootstrap.ps1 in the motortown-win KVM guest.

Runs on a machine that can ssh to the host (asean-mt-server), which has the
pywinrm venv at /tmp/wrmenv. Guest password resolution, in order:
  1. MTGUEST_PW env var (never passed on a command line, never printed)
  2. /root/.mtguest-pw on the host (chmod 600, single line)
No /tmp grep fallback - if neither source exists, provisioning fails loudly.

Flow: scp payload -> host /tmp/guest-provision -> host http.server on 8902
(virbr0) -> guest curl pulls files -> guest runs bootstrap.ps1 via WinRM.
Secrets (steam creds / update_mt.bat) NEVER ride that plain-HTTP route: they
are written inside the guest via WinRM base64 (NTLM-encrypted transport).

Optional:
  MOD_ZIP=/path/MotorTownMods_server-vX.zip  stages a mod build for step 10
  MOD_SIG_DIR=/path/UE4SS_Signatures         stages the signatures dir (zipped
                                             locally, pulled + extracted guest-side)

Usage: python3 provision_guest.py [guest-ip]   (default 192.168.122.61)
"""

import base64
import os
import subprocess
import sys
import tempfile
import zipfile

GUEST_IP = sys.argv[1] if len(sys.argv) > 1 else "192.168.122.61"
HOST = "root@asean-mt-server"
HERE = os.path.dirname(os.path.abspath(__file__))

PUSH_FILES = [
    "bootstrap.ps1",
    "vector.toml",
    "start-dedi.cmd",
    "GameUserSettings.ini.b64",
    "DediStart-task.xml",
    "MTDediWatchdog-task.xml",
    "watchdog.ps1",
]


def host_cmd(cmd: str, timeout: int = 960, check: bool = True) -> str:
    r = subprocess.run(["ssh", HOST, cmd],
                       capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError(f"host cmd failed: {cmd}\n{r.stderr[-2000:]}")
    return r.stdout


def resolve_pw() -> str:
    pw = os.environ.get("MTGUEST_PW", "")
    if pw:
        return pw
    out = host_cmd(
        "test -r /root/.mtguest-pw && head -1 /root/.mtguest-pw || true").strip()
    if out:
        return out
    sys.exit("guest password: set MTGUEST_PW or write /root/.mtguest-pw on the host")


def steam_bat() -> str | None:
    """Generate update_mt.bat from host-side secrets.

    Reads /run/agenix/steam (STEAM_USERNAME, STEAM_PASSWORD) and the beta
    branch password from /run/agenix/steam (STEAM_BETAPASSWORD) or
    /root/.mtsteam-beta (chmod 600). None of these values are printed or
    logged - they only end up in the .bat pushed to the guest over WinRM.
    Returns the file content or None when creds are unavailable.
    """
    out = host_cmd(
        "test -r /run/agenix/steam && cat /run/agenix/steam || true")
    user = pw = beta = None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("STEAM_USERNAME="):
            user = line.split("=", 1)[1]
        elif line.startswith("STEAM_PASSWORD="):
            pw = line.split("=", 1)[1]
        elif line.startswith("STEAM_BETAPASSWORD="):
            beta = line.split("=", 1)[1]
    if not beta:
        beta = host_cmd(
            "test -r /root/.mtsteam-beta && head -1 /root/.mtsteam-beta || true"
        ).strip() or None
    if not (user and pw):
        return None
    if not beta:
        print("WARN: no beta branch password (STEAM_BETAPASSWORD in agenix "
              "or /root/.mtsteam-beta) - update_mt.bat not usable")
        return None
    return (
        "+force_install_dir C:\\mtserver\r\n"
        f"+login {user} {pw}\r\n"
        f"+app_update 2223650 -beta beta -betapassword {beta} validate\r\n"
        "+quit\r\n"
    )


def mod_version() -> str | None:
    """Desired mod version from mod-versions.nix, read via ssh."""
    out = host_cmd(
        "grep -h '^  main' /opt/data/workspace/amc-server/mod-versions.nix "
        "/opt/data/workspace/*/mod-versions.nix 2>/dev/null || true")
    for line in out.splitlines():
        if '"main"' in line or line.strip().startswith("main"):
            return line.split('"')[1]
    return None


def zip_dir(src: str, dst: str) -> None:
    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _dirs, files in os.walk(src):
            for f in files:
                full = os.path.join(root, f)
                z.write(full, os.path.relpath(full, os.path.dirname(src)))


def push_secret_via_winrm(s, guest_path: str, content: bytes) -> None:
    b64 = base64.b64encode(content).decode()
    ps = (
        "$d = Split-Path '%s'; if ($d) { New-Item -ItemType Directory -Force "
        "-Path $d | Out-Null }; "
        "[IO.File]::WriteAllBytes('%s', [Convert]::FromBase64String('%s'))"
        % (guest_path, guest_path, b64)
    )
    r = s.run_ps(ps)
    if r.status_code != 0:
        raise RuntimeError(f"secret push failed for {guest_path}: "
                           f"{r.std_err.decode(errors='replace')[:500]}")


def main() -> None:
    pw = resolve_pw()

    host_cmd("rm -rf /tmp/guest-provision && mkdir -p /tmp/guest-provision")
    subprocess.run(["scp"] + [os.path.join(HERE, f) for f in PUSH_FILES]
                   + [f"{HOST}:/tmp/guest-provision/"], check=True)

    # desired mod version (from mod-versions.nix) for bootstrap step 10
    mv = mod_version()
    if mv:
        with open(os.path.join(HERE, "mod-version.txt"), "w") as f:
            f.write(mv + "\n")
        subprocess.run(["scp", os.path.join(HERE, "mod-version.txt"),
                        f"{HOST}:/tmp/guest-provision/"], check=True)
        PUSH_FILES.append("mod-version.txt")
        print(f"desired mod version: {mv}")

    # optional mod zip staging (goes over HTTP; it is a public release artifact)
    staged_mod = staged_sig = False
    mod_zip = os.environ.get("MOD_ZIP", "")
    if mod_zip:
        if not os.path.isfile(mod_zip):
            sys.exit(f"MOD_ZIP not a file: {mod_zip}")
        host_cmd("mkdir -p /tmp/guest-provision/mod")
        subprocess.run(["scp", mod_zip, f"{HOST}:/tmp/guest-provision/mod/"],
                       check=True)
        staged_mod = os.path.basename(mod_zip)
        print(f"staged mod zip: {staged_mod}")
        sig = os.environ.get("MOD_SIG_DIR", "")
        if sig and os.path.isdir(sig):
            zpath = os.path.join(HERE, "UE4SS_Signatures.zip")
            zip_dir(sig, zpath)
            subprocess.run(["scp", zpath, f"{HOST}:/tmp/guest-provision/mod/"],
                           check=True)
            os.remove(zpath)
            staged_sig = True
            print("staged UE4SS_Signatures.zip")

    # serve payload to the guest over virbr0
    host_cmd("pkill -f 'http.server 8902' 2>/dev/null; true")
    host_cmd("cd /tmp/guest-provision && setsid nohup python3 -m http.server 8902 "
             "--bind 192.168.122.1 >/dev/null 2>&1 < /dev/null & sleep 1")

    pull_lines = "".join(
        f"curl.exe -s -o C:\\mtserver\\bootstrap\\{f} http://192.168.122.1:8902/{f}\n"
        for f in PUSH_FILES
    )
    pull_lines += "New-Item -ItemType Directory -Force -Path C:\\mtserver\\bootstrap\\mod\\sig | Out-Null\n"
    if staged_mod:
        pull_lines += (
            f"curl.exe -s -o C:\\mtserver\\bootstrap\\mod\\{staged_mod} "
            f"http://192.168.122.1:8902/mod/{staged_mod}\n"
        )
    if staged_sig:
        pull_lines += (
            "curl.exe -s -o C:\\mtserver\\bootstrap\\mod\\sig.zip "
            "http://192.168.122.1:8902/mod/UE4SS_Signatures.zip\n"
            "Expand-Archive -Force C:\\mtserver\\bootstrap\\mod\\sig.zip "
            "C:\\mtserver\\bootstrap\\mod\\sig\\\n"
        )
    runner = (
        "New-Item -ItemType Directory -Force -Path C:\\mtserver\\bootstrap | Out-Null\n"
        + pull_lines
        + 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\\mtserver\\bootstrap\\bootstrap.ps1\n'
    )

    import winrm  # requires the host's /tmp/wrmenv venv on PATH
    s = winrm.Session(f"http://{GUEST_IP}:5985/wsman",
                      auth=("Administrator", pw), transport="ntlm")

    # secrets first, over WinRM (NTLM-encrypted), never over plain HTTP
    bat = steam_bat()
    if bat:
        push_secret_via_winrm(s, "C:\\steamcmd\\update_mt.bat", bat.encode())
        print("update_mt.bat pushed via WinRM (creds never on the HTTP route)")
    else:
        print("WARN: no steam creds on host (/run/agenix/steam) - "
              "update_mt.bat not pushed, dedi install stays manual")

    r = s.run_ps(runner)
    print(r.std_out.decode(errors="replace"))
    err = r.std_err.decode(errors="replace")
    if err:
        print("STDERR:", err[:2000])

    host_cmd("pkill -f 'http.server 8902' 2>/dev/null; true")
    print("PROVISION DONE")


if __name__ == "__main__":
    main()
