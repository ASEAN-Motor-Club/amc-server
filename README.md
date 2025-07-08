# ASEAN Motortown Club Server

## Usage
Please use Nix. Use this to install Nix on your system:
https://zero-to-nix.com/concepts/nix-installer/

Run `nix develop` (or look into `nix-direnv`) to get the dev shell.


## Dedicated Server Mod development
To facilitate a faster feedback look between code changes and testing, you can modify the files directly.

1. SSH into the server,
2. The dedi files are in `/var/lib/motortown-server`, modify them directly or via `scp`,
3. To restart the service, use `sudo systemctl restart motortown-server`


## Deployment
You will need root SSH access to deploy the server.

### Container Deployment
Some stuff, like the radio, has been bootstrapped to make deployment easier.
They run on a NixOS container, and therefore behaves like a standalone server.

For example, to deploy the radio on the experimental server, do:
```bash
nix-develop
deploy amc-radio-experimental
```
See `nix/deploy.nix` for a list of special deployments.

### General Deployment
Deploy to any arbitrary server with SSH access. The hostname of the server and `nixosConfiguration.${hostname}` must match!

```bash
nix-develop
deploy --ssh-port=22 root@$SERVER_IP
```


## Adding/Updating Secrets
Secrets are encrypted by the servers' public SSH keys, and can only be read by the server.

### Example

```bash
cd secrets
# steam.env is an gitignored file
cat steam.env | ragenix --editor - -e steam.age
# this will produce steam.age, which is the encrypted file
```


