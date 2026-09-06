# AMC Server — Agent Guide

## Overview

This is the **ASEAN Motor Club** monorepo, managing game servers, backend services, and peripheral services for Motor Town community infrastructure.

## Architecture

```
amc-server/                  # NixOS flake monorepo
├── amc-backend/             # Django backend (submodule) — API, arq worker, Discord bot
├── amc-peripheral/          # Peripheral services (submodule) — radio, Discord bots
├── motortown-server-flake/  # Motor Town game server (submodule)
├── necesse-server/          # Necesse game server (submodule)
├── eco-server/              # Eco game server (submodule)
├── machines/                # Machine-specific NixOS configurations
│   ├── asean-mt-server/     # Main server (game + backend + event container)
│   └── amc-peripheral/      # Peripheral server (radio, sharry, staging test server)
├── secrets/                 # Encrypted secrets (ragenix)
├── nix/                     # Shared Nix utilities
└── flake.nix                # Root flake wiring everything together
```

## Servers

| Hostname            | SSH Access                   | Role                                       |
|---------------------|------------------------------|---------------------------------------------|
| `asean-mt-server`   | `ssh root@asean-mt-server`   | Motor Town game server + amc-backend (production) + event container |
| `amc-peripheral`    | `ssh root@amc-peripheral`    | Radio station, Sharry, peripheral Discord bots, staging test server |

Both servers are accessed via **Tailscale** SSH.

### SSH users

| User    | Use for                                                        |
|---------|----------------------------------------------------------------|
| `root`  | systemctl, journalctl, NixOS deploy, uploading to `/var/lib/mod-releases/` |
| `steam` | File operations on `/var/lib/motortown-server/` (state directory)          |

Use `steam@` for any `scp`/`ssh` that creates or modifies files in the game server state directory. Files created as `root` can't be overwritten by the `steam`-owned service on restart.

## Key Subsystems

### amc-backend (production, on `asean-mt-server`)

The production backend runs directly on `asean-mt-server` (host, not container). Key services:
- `amc-backend` — Django API via uvicorn (port 9000)
- `amc-worker` — arq worker + Discord bot (runs together in one process)

### Staging test server (on `amc-peripheral`)

The staging test server runs directly on `amc-peripheral` (no container). It includes:
- Motor Town game server (port 27778)
- Staging amc-backend (port 9001)
- Staging amc-log-listener (RELP port 2515)

### amc-peripheral (on `amc-peripheral` server)

Runs radio station and peripheral Discord bots as a regular systemd service.

## Deployment

Deployment runs `nixos-rebuild switch` (build on target) via the `deploy` script in `devShells.default` (defined in [`nix/scripts.nix`](nix/scripts.nix)):

```bash
nix develop --command deploy root@asean-mt-server   # Deploy to main server
nix develop --command deploy root@amc-peripheral    # Deploy to peripheral server
```

**Deploy base: use the dedicated deploy clone, not the main workspace.** Tasks run
in parallel worktrees; the main workspace must never be a deploy input (it caused
the 2026-09-05 concurrent-deploy race where a deploy shipped a sibling branch).

- `/opt/data/workspace/amc-deploy` — clean clone of `origin/master`, no
  submodules. Non-overridden flake inputs ship their `flake.lock` pins.
- Baseline deploy: `cd /opt/data/workspace/amc-deploy && nix develop --command deploy --ff-base root@<host>`
- Test a task worktree: add `--override-input amc-backend=/opt/data/workspace/amc-backend-wt-<topic>`
  (repeatable `input=path`; the script prints each override target's HEAD and dirty state).
- Test a parent-flake change (flake.nix, machines/, mod-versions.nix): deploy
  from the task worktree directly, overriding only inputs the task also touches.
- Freshness model: merged submodule code ships when its pin-bump PR merges, or
  earlier via an explicit `--override-input`. `--local-submodules` restores the
  legacy ship-local-checkout-HEADs behavior (requires initialized submodules).

## Skills

| Skill | Description |
|-------|-------------|
| [server-access](.agents/skills/server-access/SKILL.md) | SSH access, container access, and debugging on AMC servers |
| [secrets-management](.agents/skills/secrets-management/SKILL.md) | Managing ragenix-encrypted secrets |
