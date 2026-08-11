# Yumemi — Operational Context (amc-peripheral)

Project/workflow context for the Yumemi agent. Persona lives in `SOUL.md`.

## Host Context

- **Host**: `amc-peripheral` (NixOS, flake-based monorepo)
- **Architecture**: x86_64-linux
- **Deployment**: `nix develop --command deploy root@amc-peripheral`
- **Repository**: `git@github.com:ASEAN-Motor-Club/amc-server.git` (cloned at
  `/opt/data/workspace/amc-server`)

## Capabilities

- **Terminal**: Execute shell commands on the host via the mounted Podman socket.
- **Host SSH**: SSH into `root@host.docker.internal` using the deploy key for
  privileged operations (`nixos-rebuild`, `systemctl`, etc.).
- **Files**: Read and write files in `/opt/data/workspace/amc-server` and
  persistent directories under `/opt/data`.
- **Web**: Search, extract, and browse the web.
- **Skills**: Bundled skills are synced automatically.
- **Memory**: Persistent memory is enabled with auto-persist.
- **Cron**: Scheduled tasks are enabled.

## AMC Peripheral Services

| Service | Description |
|---|---|
| `amc-radio` | Liquidsoap radio + Discord bots |
| `fallback` | Fallback radio stream |
| `amc-bot` | Discord bots |
| `kimaki` | Discord↔OpenCode bridge (Jarvis) |
| `amc-backend` | Staging Django API (uvicorn, port 9001) |
| `motortown-server` | Staging Motor Town game server (port 27778) |
| `amc-log-listener` | Staging RELP log listener (port 2515) |
| `podman-hermes-agent` | This agent (Yumemi) |
| `nginx` | Reverse proxy |
| `postgresql` | Staging database (with PostGIS) |
| `sharry` | File sharing service |

## GitHub (asean-coding-agent[bot])

Git push/fetch to GitHub uses HTTPS + the GitHub App credential helper
(auto-refreshing 1-hour installation token). No SSH key or PAT needed.
Commits and PRs attribute to `asean-coding-agent[bot]`.

For the `gh` CLI (PRs, Actions, issues), mint a token first:

```
export GH_TOKEN=$(gh-token)
gh pr create --base master --fill --draft
gh run list
gh run view <run-id>
```

Tokens expire after 1 hour — re-run `gh-token` if a command fails with 401.
Do NOT create or suggest a PAT; the App handles everything.

## Database

The staging AMC PostgreSQL database is accessible:

```
psql -h ::1 -U amc -d amc
```

- Use `\dt` to list tables, `\d tablename` for column details.
- Use `SET statement_timeout = '30s';` for safety.
- This is the **staging** database on amc-peripheral — distinct from the
  production database on `asean-mt-server`.

## Deployment

Deploy to the peripheral server:

```
cd /opt/data/workspace/amc-server
nix develop --command deploy root@amc-peripheral
```

Or trigger the self-deploy service:

```
sudo systemctl start amc-peripheral-deploy
```

Deploy to the main server (via Tailscale SSH — socket mounted, ProxyCommand configured):

```
cd /opt/data/workspace/amc-server
nix develop --command deploy root@asean-mt-server --skip-checks
```

The build happens on `asean-mt-server` (`--build-host`). Use `--skip-checks`
to bypass pre-deploy validation (alejandra, pytest) inside the container.
Submodules are initialised at startup — the `--override-input` paths resolve.

For rollbacks:
```
nix develop --command rollback root@asean-mt-server
```

After a deploy to asean-mt-server, run the health check:
```
nix develop --command health-check root@asean-mt-server
```

## Logs

Read service logs via `journalctl`:

- `journalctl -u amc-radio -n 100` — last 100 lines of the radio service
- `journalctl -u amc-bot --since '1 hour ago'` — bot logs
- `journalctl -u amc-backend -f` — follow staging backend in real-time

## Modding references

- **MTDediMod / UE4SS**: skills and debugging guides live in the workspace at
  `amc-server/.agents/skills/mtdedimod-*`. Consult them before editing UE4SS
  Lua (CargoExtractor/SDK, Lua GC pitfalls).
- **PAK modding**: game version matching matters — a pak built for the wrong
  Motor Town version crashes the dedicated server. Check `mod-versions.nix`
  and the `motortown-server` config for the active version.

## Operational Guidelines

1. **Dry-run first**: Before deploying, consider running `nix flake check --no-build`
   to validate the configuration.
2. **Never expose secrets**: Do not paste API keys, tokens, or private keys
   into Discord or any external channel.
3. **Coordinate changes**: If you plan to restart services or run migrations,
   warn the team first.
4. **Submodules**: The amc-server repo has submodules (amc-backend, amc-peripheral,
   motortown-server-flake, etc.). Use `git submodule update --init --recursive`
   after pulling.
