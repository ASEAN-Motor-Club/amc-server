# SPDX-License-Identifier: Unlicense
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    motortown-server.url = "github:ASEAN-Motor-Club/motortown-server-flake";
    motortown-server.inputs.nixpkgs.follows = "nixpkgs";
    ragenix.url = "github:yaxitech/ragenix";
  };

  outputs =
    { self, nixpkgs, motortown-server, ragenix, ... }@inputs:
    let
      eachSystem = f: nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          buildInputs = with pkgs; [
            ragenix.packages.aarch64-darwin.default
            (import ./nix/deploy.nix { inherit pkgs; })
          ];
        };
      });

      nixosModules.motortown-server-experimental =  { config, ... }: {
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

      nixosConfigurations.amc-experimental = nixpkgs.lib.nixosSystem {
        modules = [
          ragenix.nixosModules.default
          ./configuration.nix
          ./hardware-configuration.nix
          motortown-server.nixosModules.default
          self.nixosModules.motortown-server-experimental
        ];
      };
    };
}
