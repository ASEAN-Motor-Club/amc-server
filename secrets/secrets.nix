let
  experimentalServer = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMZEWhiQbX3bOqA4ufGG5RRICY/tVbAODi6qRVDz/Y9D";
  experimentalServerContabo = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILh78cPCu//hwRYDPSXfPEGMwxsktNkjfrb2yhF56kO7";
  asean-mt-server = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH7Qg2bxMvXPlkcO148QVU5QtdreMY8bfBfMUADOuOCO";
  peripheral = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINuVGOXjiO1bfDBHLjdbi3t9mkLrN8UnHJfLKniHj3+H";
in {
  "steam.age".publicKeys = [experimentalServer experimentalServerContabo asean-mt-server];
  "tailscale.age".publicKeys = [experimentalServer experimentalServerContabo asean-mt-server];
  "backend.age".publicKeys = [experimentalServer experimentalServerContabo peripheral asean-mt-server];
  "cookies.age".publicKeys = [experimentalServer experimentalServerContabo peripheral asean-mt-server];
  "ecoUserToken.age".publicKeys = [experimentalServer experimentalServerContabo peripheral asean-mt-server];
  "github-runner-token.age".publicKeys = [asean-mt-server];
  "github-runner-ssh.age".publicKeys = [asean-mt-server];
  "peripheral-bots.age".publicKeys = [peripheral];
}
