---
name: server-access
description: SSH access to AMC servers and NixOS container access for debugging amc-backend
---

# Server Access & Debugging

## SSH Access

Both servers require **Tailscale** for SSH.

```bash
ssh root@asean-mt-server     # Main server (game + backend)
ssh root@amc-peripheral      # Peripheral server (radio, bots)
```

## NixOS Container Access (amc-backend)

The `amc-backend` runs inside a NixOS container on `asean-mt-server`. You **cannot** access its services with regular `systemctl` from the host — you must use `nixos-container`.

### Run commands inside the container

```bash
# General pattern
nixos-container run amc-backend -- <command>

# Check service status
nixos-container run amc-backend -- systemctl status amc-worker
nixos-container run amc-backend -- systemctl status amc-backend

# View logs
nixos-container run amc-backend -- journalctl -u amc-worker -n 100 --no-pager
nixos-container run amc-backend -- journalctl -u amc-worker --since '1 hour ago' --no-pager

# Restart a service
nixos-container run amc-backend -- systemctl restart amc-worker
```

### Django management commands

```bash
nixos-container run amc-backend -- su -s /bin/sh amc -c \
  'DJANGO_SETTINGS_MODULE=amc_backend.settings amc-manage <command>'
```

For shell queries:
```bash
nixos-container run amc-backend -- su -s /bin/sh amc -c \
  'DJANGO_SETTINGS_MODULE=amc_backend.settings amc-manage shell -c "<python code>"'
```

> [!IMPORTANT]
> Django commands must run as the `amc` user and require `DJANGO_SETTINGS_MODULE=amc_backend.settings`.

### Database access

```bash
nixos-container run amc-backend -- su -s /bin/sh amc -c 'psql'
```

## Services Inside the Container

| Service | systemd unit | Description |
|---------|-------------|-------------|
| Django API | `amc-backend` | uvicorn ASGI server |
| Worker + Discord Bot | `amc-worker` | arq worker with Discord bot in a ThreadPoolExecutor |
| Dummy Server | `dummy-server` | Test/dummy server |

### amc-worker architecture

The `amc-worker` process runs `arq` which:
1. **On startup**: creates an `aiohttp` session pool and starts the **Discord bot** in a `ThreadPoolExecutor`
2. **Cron jobs**: `monitor_jobs`, `monitor_webhook`, `monitor_locations`, `send_event_embeds`, etc.
3. **Task queue**: processes `process_log_line` tasks from Redis
4. **Discord bot**: loads cogs (`JobsCog`, `EventsCog`, `RoleplayCog`, etc.) with their own `tasks.loop` schedules

> [!CAUTION]
> The Discord bot runs in a separate thread inside the arq worker. If the bot crashes or a cog's `tasks.loop` dies from an unhandled exception, the arq worker process will continue running normally — only the bot/cog functionality stops silently. Check for both arq cron output AND Discord-specific logs when debugging.

## Troubleshooting Checklists

### "Discord channel not updating"

1. Check if `amc-worker` is running: `systemctl status amc-worker`
2. Check recent logs for the specific loop: `journalctl -u amc-worker --since '1 hour ago' | grep -i "<loop_name>"`
3. Look for Discord errors: `journalctl -u amc-worker --since '3 days ago' | grep -i "discord.*error\|DiscordServerError\|Traceback"`
4. If a `tasks.loop` died, restart the worker: `systemctl restart amc-worker`

### "arq cron job not running"

1. Check worker status and recent logs
2. Look for Python exceptions in journal
3. Restart if needed

## Host-Level Services (asean-mt-server)

These run directly on the host, not in containers:

- `motortown-server` — Main Motor Town game server
- `motortown-server-containers-test` — Test game server container
- `motortown-server-containers-event` — Event game server container
- `container@amc-backend` — The NixOS container itself
- `container@amc-log-listener` — Log ingestion container (rsyslogd + RELP)
