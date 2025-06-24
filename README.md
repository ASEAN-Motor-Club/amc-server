# ASEAN Motortown Club Server

## Usage
Nix/NixOS knowledge assumed.
Run `nix develop` or use `nix-direnv` to get the dev shell.


## Mod development
To facilitate a faster feedback look between code changes and testing, you can modify the files directly.

1. SSH into the server,
2. The dedi files are in `/var/lib/motortown-server`, modify them directly or via `scp`,
3. To restart the service, use `sudo systemctl restart motortown-server`


## Secrets
Secrets are encrypted by the servers' public SSH keys, and can only be read by the server.

### Example

```bash
cd secrets
# steam.env is an gitignored file
cat steam.env | ragenix --editor - -e steam.age
# this will produce steam.age, which is the encrypted file
```


## Deployment
You will need root SSH access to deploy the server.

`deploy root@$SERVER_IP`

