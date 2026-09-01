#!/usr/bin/env python3
"""Fail if a submodule gitlink and its flake.lock pin disagree.

Join key: the lock entry's locked.repo must equal the submodule URL's repo
name (basename without .git and query string). This is robust against
input-name != submodule-path mismatches (e.g. flake input `motortown-server`
vs submodule path `motortown-server-flake`).

Modes:
  (default)  gitlinks read from the HEAD tree  — for PR/master guards
  --index    gitlinks read from the index      — for the bump job after
             `git update-index --cacheinfo` (changes are staged, not committed)

Submodules with no matching flake.lock entry (e.g. MTDediMod, whose releases
ride mod-versions.nix, not the pin) are skipped.
"""

import json
import posixpath
import subprocess
import sys


def gitlink_urls() -> dict[str, str]:
    ls = subprocess.run(
        ["git", "ls-files", "-s"], capture_output=True, text=True, check=True
    ).stdout
    paths = [
        line.split("\t", 1)[1]
        for line in ls.splitlines()
        if line.startswith("160000 ")
    ]
    urls = {}
    for path in paths:
        url = subprocess.run(
            ["git", "config", "--file", ".gitmodules", "--get", f"submodule.{path}.url"],
            capture_output=True,
            text=True,
        ).stdout.strip()
        if url:
            urls[path] = url
    return urls


def repo_name(url: str) -> str:
    url = url.split("?", 1)[0]          # drop ?lfs=1 etc.
    url = url.removesuffix(".git")
    return posixpath.basename(url)


def tree_gitlink(path: str) -> str | None:
    out = subprocess.run(
        ["git", "ls-tree", "HEAD", "--", path], capture_output=True, text=True, check=True
    ).stdout
    for line in out.splitlines():
        meta, _ = line.split("\t", 1)
        _mode, otype, sha = meta.split()
        if otype == "commit":
            return sha
    return None


def main() -> int:
    use_index = "--index" in sys.argv

    with open("flake.lock") as f:
        lock = json.load(f)
    nodes = lock["nodes"]
    root = nodes[lock["root"]] if isinstance(lock["root"], str) else lock["root"]

    lock_revs: dict[str, str] = {}
    for node_id in root["inputs"].values():
        locked = nodes[node_id].get("locked", {})
        repo, rev = locked.get("repo"), locked.get("rev")
        if repo and rev:
            lock_revs[repo] = rev

    drift: list[str] = []
    checked: list[str] = []
    skipped: list[str] = []
    for path, url in sorted(gitlink_urls().items()):
        repo = repo_name(url)
        expected = lock_revs.get(repo)
        if expected is None:
            skipped.append(f"{path} (no flake.lock entry for {repo})")
            continue
        if use_index:
            out = subprocess.run(
                ["git", "ls-files", "-s", "--", path],
                capture_output=True,
                text=True,
                check=True,
            ).stdout
            sha = out.split()[2] if out else None
        else:
            sha = tree_gitlink(path)
        if sha is None:
            skipped.append(f"{path} (no gitlink found)")
            continue
        checked.append(path)
        if sha != expected:
            drift.append(
                f"DRIFT {path}: gitlink={sha[:12]} flake.lock({repo})={expected[:12]}"
            )

    for line in sorted(drift):
        print(line)
    if drift:
        print(
            f"\n{len(drift)} pin(s) out of sync — bump gitlink + flake.lock "
            "together in one PR (self-deploys consume flake.lock, manual "
            "deploys consume the gitlink)."
        )
        return 1
    print(f"pins in sync: {', '.join(checked) or '(none)'}")
    if skipped:
        print(f"skipped (no lock entry): {'; '.join(skipped)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
