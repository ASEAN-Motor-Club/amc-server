# SPDX-License-Identifier: Unlicense
{
  inputs = {
    self.submodules = true;
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    motortown-server.url = "path:mt-server-flake";
    amc-backend.url = "path:amc-backend";
    amc-radio.url = "path:amc-radio";
    amc-radio.inputs.nixpkgs.follows = "nixpkgs";
    ragenix.url = "github:yaxitech/ragenix";
  };

  outputs =
    { self, nixpkgs, motortown-server, amc-backend, amc-radio, ragenix, ... }@inputs:
    let
      eachSystem = f: nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          buildInputs = with pkgs; [
            ragenix.packages.aarch64-darwin.default
            (import ./nix/deploy.nix { inherit pkgs; })
            pkgs.nixos-rebuild
          ];
        };
      });

      nixosModules.motortown-server-experimental =  { config, pkgs, ... }: {
        services.rsyslogd = {
          enable = true;
          extraConfig = ''
            global(environment=[
              "DJANGO_SETTINGS_MODULE=amc_backend.settings",
              "PYTHONUNBUFFERED=1"
            ])
            module(load="imfile")
            module(load="omprog")

            input(type="imfile"
              File="/var/lib/motortown-server/MotorTown/Saved/ServerLog/*.log"
              Tag="mt-server"
              ruleset="mt"
            )
            Ruleset(name="mt") {
              action (
                type="omfile"
                file="/var/log/mt-server.log"
              )
              action (
                type="omprog"
                binary="${pkgs.amc-backend}/bin/django-admin ingest_logs"
              )
            }
          '';
        };

        services.motortown-server = {
          enable = true;
          enableMods = true;
          openFirewall = true;
          user = "steam";
          credentialsFile = config.age.secrets.steam.path;
          dedicatedServerConfig =  {
            ServerName = "ASEAN Experimental";
            ServerMessage = "Welcome | Selamat Datang | Sawasdee Krub | Maligayang Pagdating\nIf you like this server, mark it as Favorite and join the Discord:\nwww.aseanmotorclub.com.\n\n[READ THE RULES]\n- Do not abandon your vehicle and block traffic\n- Only set up Companies, not Corporations\n- The full rules are available on Discord.\n\n[SERVER SETTINGS]\n- AI is enabled and max vehicles per player is 10.\n- Rent lasts 7 days\n\n[RADIO]\nTune in to our Radio ASEAN station! See the Radio page on the website for instructions.";
            Password = "";
            MaxPlayers = 10;
            MaxVehiclePerPlayer = 10;
            bAllowPlayerToJoinWithCompanyVehicles = true;
            bAllowCompanyAIDriver = true;
            MaxHousingPlotRentalPerPlayer = 1;
            MaxHousingPlotRentalDays = 10;
            HousingPlotRentalPriceRatio = 0.03;
            bAllowModdedVehicle = true;
            NPCVehicleDensity = 0.2;
            NPCPoliceDensity = 0.0;
            bEnableHostWebAPIServer = true;
            HostWebAPIServerPassword = "asean";
            HostWebAPIServerPort = 8080;
            Admins = [
              {
                UniqueNetId = "76561198378447512";
                Nickname = "freeman";
              }
              {
                UniqueNetId = "76561198041602277";
                Nickname = "KambingPanas";
              }
            ];
          };
        };
      };

      nixosModules.amc-radio-experimental = { config, lib, ... }: {
        imports = [ amc-radio.nixosModules.amc-radio ];
        boot.isContainer = true;
        nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
        networking.hostName = lib.mkForce "amc-radio-experimental";
        networking.firewall.allowedTCPPorts = config.services.openssh.ports;
        services.openssh.enable = true;
        services.openssh.ports = lib.mkDefault [222];
        users.users.root.openssh.authorizedKeys.keys = lib.mkDefault [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJcMiNGgqQtOeACMso3CgZz2J3X8Ne8RxsZrQcsnoewU fmnxl-m2"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO75UM3IHNzJKUxgABH6OHa/hxfQIoxTs+nGUtSU1TID"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPs3C6y03LXc81nENxb5Q6S91XMtH/+iu5/JhYNedJj8"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILMW89zmdnCyR7EK7thvGAEW8bW8/aDXsbxd5/bJcQKT"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA2WPVkEwdrGTjZ9JEiGYWyhC0Q/Pet1iP3LJz9ewpmd"
        ];
        services.amc-radio.enable = true;
      };

      nixosConfigurations.amc-radio-experimental = nixpkgs.lib.nixosSystem {
        modules = [
          self.nixosModules.amc-radio-experimental
        ];
      };

      nixosConfigurations.amc-experimental = nixpkgs.lib.nixosSystem {
        modules = [
          ragenix.nixosModules.default
          motortown-server.nixosModules.default
          amc-backend.nixosModules.backend
          ./configuration.nix
          ./hardware-configuration.nix
          self.nixosModules.motortown-server-experimental
          ({ config, ... }: {
            containers.amc-radio-experimental = {
              autoStart = true;
              config = self.nixosModules.amc-radio-experimental;
            };
          })
        ];
      };
    };
}
