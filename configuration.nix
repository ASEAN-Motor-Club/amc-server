{ lib, pkgs, config, ... }: {
  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  networking.hostName = "amc-experimental";
  networking.domain = "";
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [80 443 22];
  };
  networking.networkmanager.enable = true;
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJcMiNGgqQtOeACMso3CgZz2J3X8Ne8RxsZrQcsnoewU fmnxl-m2''
    ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO75UM3IHNzJKUxgABH6OHa/hxfQIoxTs+nGUtSU1TID''
  ];
  users.users.steam = {
    isNormalUser  = true;
    home  = "/home/steam";
    description  = "Steam";
    openssh.authorizedKeys.keys = [
      ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJcMiNGgqQtOeACMso3CgZz2J3X8Ne8RxsZrQcsnoewU fmnxl-m2''
    ];
    extraGroups = [ "modders" ];
  };
  users.users.freeman = {
    isNormalUser  = true;
    description  = "Freeman";
    openssh.authorizedKeys.keys = [
      ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJcMiNGgqQtOeACMso3CgZz2J3X8Ne8RxsZrQcsnoewU fmnxl-m2''
    ];
    extraGroups = [ "modders" ];
  };
  users.users.kambing = {
    isNormalUser  = true;
    description  = "Kambing";
    openssh.authorizedKeys.keys = [
      "ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1MjEAAACFBAAHjoR/hPAAW8Bdg9UHm0M82YOP4K80cXjTQGDFhFXu+1XsN0LA5kflclnbGnVabITg4MbStfNdJewNMa95u7j+WQC9+z2v3jaqR15KphA3RTCirDCRq1QBW61I8NWpIiHdhAlERHw9kWHtQajKIjUnS+tijxLTamf5OgO4+l4CB6MZ/w=="
      "ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1MjEAAACFBAG+LQz7JhKpIRpFwiI6iUFW9O1UDC8URQMKitMI1k8/+QMLR9ju3xr2VQIyh/fQOFMVN5miVx2WevyjiZju6+5SuwDNNFyMNvXNFGWUrmGNr/7YWbo0jiLidc/GGldcbC8EQX9xnj7S6lp1xfaQDO+5cYx1Vvbi01Yy+ZQBluYt8tTW5w=="
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDZg9/W9XT+JLXbuHOVQe8rBY/vDE+0jUgXaKLuG9NpBxE/pE8jiC8pFNOBS5EjLMXJWhQcJxoeeUF9rvt+IQjm5BZveC2/SE766l+rDemtopjabO4T6fxQupK8sF/D0km7evSFtdOrE0VS033awdi+qywqk35BFS9I98pVL5muL5u4LjJzSfc6nBgFcl0TvlSzW2EH3PDWOw2F6k7PLKWOemCX8CNjHqrwtjy7cthk7/jCmwVAGDa9/MFRPTsSCTLw5dUk4dJz2TA6ai7fyiM9n1eCvBhLvWCN06DQvU9lv695r0qa+54U3rQIKKtrunKZd8tZ6NMPH5slpVen6MFUyV5oIESTFsBQ45jbJmXfYTNw6jeYumlOhDTZhLCenIJcZ/bKY7BLLkoTq7SwivY32FK6wsh/d5RFl9bPP2yaUSlEie7Z8fyNMfFeIqWLMYFHlSyVRkR0ii+je+vM2y2JRdJoFRD/l0y/Qehz68WjPEOzyxKf5LBwKzcWPK4hmDitQxNIUQ6iKOySzPBJHMJWyKiarbURLsO+FJUWWpyIqhVD+R509g7dxVAPxJ2X/uejVgD8DrphqDOsk1COkgqFwCaX/+n5eRjFnX55v+xe6M4uab0bknu5FjHGzZCf8yTUaHyYvv17pwv9Ik02b4FAixBO/5VQe8jtL3NWrV8FvQ=="
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDIoXSAtm0gk3yBFlW+ZDpcwp9RUdmwAh171TiLnFetaTzT1ySNuObLxbB+GvSJGuzNchbHXa2m6WACR0EqjAMMX12P2e1pWRyyE65AJcQ8lbYeK1yOa9jBrGiJcGpqLeIR+EaIau73YTgRTUjoTj1W6rvlikZCMFWpPPhEiUNAeOfCItOko1FUFdOavS4QoT4x39nm+DS9fG9nWUn7vkE4o4lJkD680HOr17XxlxoPyQ0U2jgbkWUoFUmGMcCd0EU6W84WqKIFh8U6SbVSBBldM+R9Cng7274MnpclXyND1oeP7m4+vL7829RflS+8jMWz3pkmjY1tNZ3/Z6S5z0rwSxYAYL0qTwxUCoyLc6qYThT0CdKLNiEE0xJB9IBdm+/t3bXsX+LZjFzzEAUqA8qfdmY7PUBuXa124KM3qStORhoOz2ZHSYFoohhRjXKTWHGfANE87TKNh7OfRfOlFtlFThDWkzBXfpjSQnLiKY9T7ZCr1TPcIL9yToE2ZbnMovM+7UdtzfrWKaBdKr2/HzZtWYGdeIsN4p4key/o0IwByJMzXWJyGj3HMaQEaJao3XLMeSkaw0qB1L33MzLjtoDF5MapaunpQi/DqGEvfsM68KnxsDP02z+SdJHltIMUyTv01w0xvcBH9hYNQ7QABU0eXaiMBFfewykpPCy0SSqJlw=="
    ];
    extraGroups = [ "modders" ];
  };
  users.users.meehoi = {
    isNormalUser  = true;
    description  = "Meehoi";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIUfkuxtTxshbjadPUfsltYHbPmrWDuIaqGK71wLooIL"
    ];
    extraGroups = [ "modders" ];
  };
  system.stateVersion = "23.11";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  security.sudo.extraRules = [
    {
      groups = [ "modders" ];
      commands = [
        {
          command = "/run/current-system/sw/bin/systemctl restart motortown-server";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  environment.systemPackages = with pkgs; [
    kakoune
    htop
  ];

  age.secrets.steam = {
    file = ./secrets/steam.age;
    mode = "400";
    owner = "steam";
  };

  users.groups.nginx = {};
  users.groups.web-content = {};
  users.groups.sftpuser = {};

  users.users.nginx.extraGroups = [ "web-content" ];

  services.nginx = {
    enable = true;
    user = "nginx";
    group = "web-content";
    virtualHosts."experimental.aseanmotorclub.com" = {
      enableACME = false;
      forceSSL = false;
      root = "/var/www/amc-web";
    };
  };

  users.users.sftpuser = {
    isNormalUser = true;
    home = "/var/www/uploads/sftpuser";
    group = "sftpuser";
    extraGroups = [ "web-content" ];
    shell = "${pkgs.shadow}/bin/nologin";
    openssh.authorizedKeys.keys = [
      ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJcMiNGgqQtOeACMso3CgZz2J3X8Ne8RxsZrQcsnoewU fmnxl-m2''
    ];
  };
  users.groups.sftpuser = {};

  services.openssh.extraConfig = ''
    # Match the SFTP user group.
    Match Group sftpuser
      # Force the use of the internal SFTP server.
      ForceCommand internal-sftp -u 0027
      # Chroot the user to their home directory.
      ChrootDirectory %h
      # Disable TCP forwarding and X11 forwarding for security.
      AllowTcpForwarding no
  '';

  systemd.services.setup-upload-dir = {
    description = "Set up permissions for the SFTP upload directory";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = with pkgs; ''
        ${coreutils}/bin/mkdir -p /var/www/uploads/sftpuser
        ${coreutils}/bin/chown root:sftpuser /var/www/uploads/sftpuser
        ${coreutils}/bin/chmod 755 /var/www/uploads/sftpuser
        ${coreutils}/bin/mkdir -p /var/www/uploads/sftpuser/files
        ${coreutils}/bin/chown sftpuser:web-content /var/www/uploads/sftpuser/files
        ${coreutils}/bin/chmod 775 /var/www/uploads/sftpuser/files
      '';
    };
  };
}
