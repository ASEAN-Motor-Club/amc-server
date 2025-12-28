# ASEAN Motor Club Server Infrastructure

This monorepo manages the infrastructure and deployment for the ASEAN Motor Club (AMC) game servers and backend services. It is a NixOS-based setup using Nix Flakes and Git submodules for individual components.

## Repository Structure

```
amc-server/
├── flake.nix                  # Entry point, defines NixOS configurations
├── configuration.nix          # Production server configuration
├── nix/deploy.nix             # Deployment script wrapper
├── amc-backend/               # [submodule] Django backend application
├── motortown-server-flake/    # [submodule] MotorTown game server module
├── necesse-server/            # [submodule] Necesse game server module
├── eco-server/                # [submodule] Eco game server module
└── amc-peripheral/            # [submodule] Discord bots and auxiliary services
```

### Key Files
- **`flake.nix`**: The Nix Flake entry point. Defines inputs using submodule paths (`path:amc-backend`, `path:motortown-server-flake`, etc.) and assembles NixOS configurations for all servers.
- **`configuration.nix`**: The main configuration file for the production game server (`asean-mt-server`). Handles networking, services (MotorTown, Necesse), and reverse proxying.
- **`nix/deploy.nix`**: A shell script wrapper around `nixos-rebuild` that uses `--override-input` to point to local submodule directories.

### Submodules
All submodules reside in the [ASEAN-Motor-Club](https://github.com/ASEAN-Motor-Club) GitHub organization:

| Submodule | Repository | Description |
|-----------|------------|-------------|
| `amc-backend` | [ASEAN-Motor-Club/amc-backend](https://github.com/ASEAN-Motor-Club/amc-backend) | Django-based backend API |
| `motortown-server-flake` | [ASEAN-Motor-Club/motortown-server-flake](https://github.com/ASEAN-Motor-Club/motortown-server-flake) | MotorTown dedicated server Nix module |
| `necesse-server` | [ASEAN-Motor-Club/necesse-server](https://github.com/ASEAN-Motor-Club/necesse-server) | Necesse game server Nix module |
| `eco-server` | [ASEAN-Motor-Club/eco-server](https://github.com/ASEAN-Motor-Club/eco-server) | Eco game server Nix module |
| `amc-peripheral` | [ASEAN-Motor-Club/amc-peripheral](https://github.com/ASEAN-Motor-Club/amc-peripheral) | Discord bots and auxiliary services |

---

## Deployment

### Prerequisites

- [Nix](https://nixos.org/download.html) installed with flakes enabled.
- [Tailscale](https://tailscale.com/) for SSH access to servers (hosts are resolved via Tailscale DNS, not IP addresses).
- [direnv](https://direnv.net/) (optional but recommended) for automatic shell environment loading.
- SSH access to the target server as `root`.

### How to Deploy

1.  **Enter the development shell**:
    If you use `direnv`, just `cd` into the directory and `direnv allow`.
    Otherwise, run:
    ```bash
    nix develop
    ```

2.  **Update submodules** (if deploying changes from a submodule):
    ```bash
    cd amc-backend  # or other submodule
    git pull origin main
    cd ..
    ```

3.  **Deploy to a host** using Tailscale hostname:
    ```bash
    # Deploy to the main production server
    deploy root@asean-mt-server
    
    # Deploy to other configurations
    deploy root@hq
    ```

    The `deploy` script executes:
    ```bash
    nixos-rebuild --target-host "$1" --build-host "$1" --flake . --fast switch \
      --override-input amc-backend ./amc-backend \
      --override-input motortown-server ./motortown-server-flake
    ```

### Important: Service Restarts

> [!IMPORTANT]
> Services are configured with **`restartIfChanged = false`**, meaning even after a successful deployment, services will NOT automatically restart.

This is intentional to allow for controlled rollouts and to avoid unexpected downtime during deployments. You must manually restart services after deploying:

#### Restarting Host Services
SSH into the server and restart the service:
```bash
ssh root@asean-mt-server
systemctl restart amc-backend-worker.service  # Example service name
systemctl restart necesse-server.service
```

#### Restarting Container Services
For containerized services (like MotorTown servers running in NixOS containers):
```bash
ssh root@asean-mt-server
nixos-container restart test   # Restart the "test" MotorTown container
nixos-container restart event  # Restart the "event" MotorTown container
```

#### Checking Service Status
```bash
systemctl status <service-name>
journalctl -u <service-name> -f  # Follow logs
```

### Configurations

- **`asean-mt-server`**: The main production server, defined in `configuration.nix` and `flake.nix`.
  - Runs the main MotorTown dedicated server
  - Runs MotorTown containers for test/event servers
  - Runs the backend API containers (`amc-backend`)
  - Runs the Necesse server
  - Runs the Eco server  
  - Hosts the main `server.aseanmotorclub.com` Nginx proxy
- **`amc-peripheral`**: A dedicated machine for auxiliary services.
  - Runs community Discord bots
  - Runs the AMC Radio service

---

## Development Workflow

### Working on a Submodule

1. **Navigate to the submodule** and make your changes:
   ```bash
   cd amc-backend
   # make changes, commit, push
   git add .
   git commit -m "feat: add new feature"
   git push origin main
   ```

2. **Update the root repo** to track the new submodule commit:
   ```bash
   cd ..  # back to amc-server root
   git add amc-backend
   git commit -m "chore: update amc-backend to latest"
   git push
   ```

3. **Deploy** using the `deploy` command:
   ```bash
   deploy root@asean-mt-server
   ```

4. **Restart the affected service** manually:
   ```bash
   ssh root@asean-mt-server
   systemctl restart amc-backend-worker.service
   ```

### Local Development

Each submodule has its own development environment. See the `README.md` in each submodule for specific instructions.

