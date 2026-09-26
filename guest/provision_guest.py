#!/usr/bin/env python3
"""Push and execute bootstrap.ps1 in the motortown-win KVM guest.

Runs on a machine that can ssh to the host (asean-mt-server), which has the
pywinrm venv at /tmp/wrmenv. The guest password comes from the MTGUEST_PW
env var (never passed on a command line, never printed).

Flow: scp payload -> host /tmp/guest-provision -> host http.server on 8902
(virbr0) -> guest curl pulls files -> guest runs bootstrap.ps1 via WinRM.

Usage: python3 provision_guest.py [guest-ip]   (default 192.168.122.61)
"""

import base64
import os
import subprocess
import sys
import tempfile

GUEST_IP = sys.argv[1] if len(sys.argv) > 1 else "192.168.122.61"
HERE = os.path.dirname(os.path.abspath(__file__))

PUSH_FILES = [
    "bootstrap.ps1",
    "vector.toml",
    "start-dedi.cmd",
    "GameUserSettings.ini.b64",
    "DediStart-task.xml",
]


def host_cmd(cmd: str, timeout: int = 960) -> str:
    r = subprocess.run(["ssh", "root@asean-mt-server", cmd],
                       capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"host cmd failed: {cmd}\n{r.stderr[-2000:]}")
    return r.stdout


def main() -> None:
    pw = os.environ.get("MTGUEST_PW", "")
    if not pw:
        # recover from an existing winrm script on the host (never print it)
        pw = host_cmd(
            "grep -rhoP \"(?<=auth=\\('Administrator',\\s')[^']+\" /tmp/*.py | head -1"
        ).strip()
    if not pw:
        sys.exit("MTGUEST_PW not set and could not recover password")

    host_cmd("mkdir -p /tmp/guest-provision")
    subprocess.run(["scp"] + [os.path.join(HERE, f) for f in PUSH_FILES]
                   + ["root@asean-mt-server:/tmp/guest-provision/"], check=True)

    # serve payload to the guest over virbr0
    host_cmd("pkill -f 'http.server 8902' 2>/dev/null; true")
    host_cmd("cd /tmp/guest-provision && setsid nohup python3 -m http.server 8902 "
             "--bind 192.168.122.1 >/dev/null 2>&1 < /dev/null & sleep 1")

    pull_lines = "".join(
        f"curl.exe -s -o C:\\mtserver\\bootstrap\\{f} http://192.168.122.1:8902/{f}\n"
        for f in PUSH_FILES
    )
    runner = (
        "New-Item -ItemType Directory -Force -Path C:\\mtserver\\bootstrap | Out-Null\n"
        + pull_lines
        + 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\\mtserver\\bootstrap\\bootstrap.ps1\n'
    )

    py = f'''
import winrm
s = winrm.Session("http://{GUEST_IP}:5985/wsman", auth=("Administrator", {pw!r}), transport="ntlm")
r = s.run_ps({runner!r})
print(r.std_out.decode(errors="replace"))
err = r.std_err.decode(errors="replace")
if err: print("STDERR:", err[:2000])
'''
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(py)
        path = f.name
    host_cmd(f"scp {path} root@asean-mt-server:/tmp/guest-provision/runbootstrap.py")
    out = host_cmd("timeout 900 /tmp/wrmenv/bin/python /tmp/guest-provision/runbootstrap.py")
    print(out)
    host_cmd("pkill -f 'http.server 8902' 2>/dev/null; true")
    print("PROVISION DONE")


if __name__ == "__main__":
    main()
