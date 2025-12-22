# ASEAN Motor Club Server Infrastructure

This monorepo manages the infrastructure and deployment for the ASEAN Motor Club (AMC) game servers and backend services. It is a NixOS-based setup using Nix Flakes and Git submodules components.

## Repository Structure

- **`flake.nix`**: The entry point for the system configuration. Defines the NixOS configurations for various servers.
- **`configuration.nix`**: The main configuration file for the production game server (`asean-mt-server`). Handles networking, services (MotorTown, Necesse), and reverse proxying.
- **`amc-backend/`**: A git submodule containing the Django-based backend application. This resides in a separate organization (`ASEAN-Motor-Club/amc-backend`) and uses an absolute URL.
- **`nix/deploy.nix`**: The deployment script wrapper around `nixos-rebuild`.

## Deployment

### Prerequisites

- [Nix](https://nixos.org/download.html) installed with flakes enabled.
- [direnv](https://direnv.net/) (optional but recommended) for automatic shell environment loading.

### How to Deploy

1.  **Enter the environment**:
    If you use `direnv`, just `cd` into the directory and `direnv allow`.
    Otherwise, run:
    ```bash
    nix develop
    ```

2.  **Deploy to a host**:
    The repository includes a `deploy` script helper. Run it with the target hostname:

    ```bash
    # Deploy to the main production server
    deploy asean-mt-server
    
    # Deploy to the HQ server
    deploy hq
    
    # Deploy to other configurations as defined in flake.nix (e.g., amc-peripheral)
    deploy amc-peripheral
    ```

    The `deploy` script executes `nixos-rebuild --target-host <host> --build-host <host> --flake . --fast switch`. It builds the configuration on the remote host (or your local machine if configured) and switches to it.

### Configurations

- **`asean-mt-server`**: defined in `configuration.nix` and `flake.nix`.
  - Runs the MotorTown dedicated server.
  - Runs the backend API containers (`amc-backend`).
  - Runs the Necesse server.
  - Hosts the main `server.aseanmotorclub.com` Nginx proxy.

## Development

- **`amc-backend`**: To work on the backend, check out the `amc-backend` submodule. Changes merged to the `amc-backend` master branch can be deployed by updating the submodule in this repository and running the deployment script.

