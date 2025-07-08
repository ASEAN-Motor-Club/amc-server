let
  experimentalServer = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMZEWhiQbX3bOqA4ufGG5RRICY/tVbAODi6qRVDz/Y9D";
  experimentalServerContabo = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILh78cPCu//hwRYDPSXfPEGMwxsktNkjfrb2yhF56kO7";
in
{
  "steam.age".publicKeys = [ experimentalServer experimentalServerContabo ];
  "tailscale.age".publicKeys = [ experimentalServer experimentalServerContabo ];
}
