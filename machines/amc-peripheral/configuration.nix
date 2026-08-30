{
  config,
  pkgs,
  lib,
  ...
}: let
  # ── GitHub App credential helpers ──────────────────────────────────
  # These generate fresh GitHub App installation tokens on demand,
  # avoiding the 1-hour token expiry issue for long-running services.
  githubAppId = "2922326";
  githubInstallationId = "111712229";
  appKeyPath = config.age.secrets.coding-agent-app-key.path;

  git-credential-github-app = pkgs.writeShellScriptBin "git-credential-github-app" ''
    set -euo pipefail
    [[ "''${1:-}" == "get" ]] || exit 0
    while IFS='=' read -r key value; do
      case "$key" in host) HOST="$value" ;; esac
    done
    [[ "''${HOST:-}" == "github.com" ]] || exit 0

    b64url() { ${pkgs.openssl}/bin/openssl base64 -e -A | ${pkgs.coreutils}/bin/tr '+/' '-_' | ${pkgs.coreutils}/bin/tr -d '='; }
    NOW=$(${pkgs.coreutils}/bin/date +%s)
    IAT=$((NOW - 60))
    EXP=$((NOW + 600))
    HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | b64url)
    PAYLOAD=$(echo -n "{\"iat\":$IAT,\"exp\":$EXP,\"iss\":\"${githubAppId}\"}" | b64url)
    SIGNATURE=$(echo -n "$HEADER.$PAYLOAD" | ${pkgs.openssl}/bin/openssl dgst -sha256 -sign "${appKeyPath}" | b64url)
    JWT="$HEADER.$PAYLOAD.$SIGNATURE"

    RESPONSE=$(${pkgs.curl}/bin/curl -sf -X POST \
      -H "Authorization: Bearer $JWT" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/app/installations/${githubInstallationId}/access_tokens" 2>&1) || {
      echo "ERROR: GitHub API request failed: $RESPONSE" >&2
      exit 1
    }
    TOKEN=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.token')
    if [[ "$TOKEN" == "null" || -z "$TOKEN" ]]; then
      echo "ERROR: Failed to extract token from response: $RESPONSE" >&2
      exit 1
    fi
    echo "protocol=https"
    echo "host=github.com"
    echo "username=x-access-token"
    echo "password=$TOKEN"
  '';

  gh-token = pkgs.writeShellScriptBin "gh-token" ''
    set -euo pipefail
    b64url() { ${pkgs.openssl}/bin/openssl base64 -e -A | ${pkgs.coreutils}/bin/tr '+/' '-_' | ${pkgs.coreutils}/bin/tr -d '='; }
    NOW=$(${pkgs.coreutils}/bin/date +%s)
    IAT=$((NOW - 60))
    EXP=$((NOW + 600))
    HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | b64url)
    PAYLOAD=$(echo -n "{\"iat\":$IAT,\"exp\":$EXP,\"iss\":\"${githubAppId}\"}" | b64url)
    SIGNATURE=$(echo -n "$HEADER.$PAYLOAD" | ${pkgs.openssl}/bin/openssl dgst -sha256 -sign "${appKeyPath}" | b64url)
    JWT="$HEADER.$PAYLOAD.$SIGNATURE"

    RESPONSE=$(${pkgs.curl}/bin/curl -sf -X POST \
      -H "Authorization: Bearer $JWT" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/app/installations/${githubInstallationId}/access_tokens" 2>&1) || {
      echo "ERROR: GitHub API request failed: $RESPONSE" >&2
      exit 1
    }
    TOKEN=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.token')
    if [[ "$TOKEN" == "null" || -z "$TOKEN" ]]; then
      echo "ERROR: Failed to extract token from response: $RESPONSE" >&2
      exit 1
    fi
    echo "$TOKEN"
  '';
in {
  imports = [
    ./hardware-configuration.nix
  ];

  boot.tmp.cleanOnBoot = true;

  # ── Swap ────────────────────────────────────────────────────────────
  # 8GB swap file on the data volume to prevent OOM kills from
  # kimaki/opencode (UAssetTool can grow to 11GB RSS).
  swapDevices = [
    {
      device = "/var/lib/data/swapfile";
      size = 8 * 1024; # 8GB in MB
    }
  ];

  # ── Disk space management ──────────────────────────────────────────
  # Cap journal logs to prevent unbounded growth (was 4GB+ uncapped)
  services.journald.extraConfig = ''
    SystemMaxUse=500M
    MaxRetentionSec=7day
  '';
  # Disable coredump storage (only CargoExtractor crashes, not useful)
  systemd.coredump.extraConfig = ''
    Storage=none
  '';
  # Rotate rsyslog's /var/log/messages — crash-looping services (e.g. staging
  # amc-worker when DB is down) can fill the disk in hours without rotation.
  services.logrotate = {
    enable = true;
    settings = {
      "/var/log/messages" = {
        frequency = "daily";
        rotate = 3;
        compress = true;
        size = "100M";
        postrotate = "systemctl kill -s HUP syslog 2>/dev/null || true";
      };
      "/var/log/warn" = {
        frequency = "weekly";
        rotate = 2;
        compress = true;
      };
    };
  };
  # Suppress verbose amc-worker cron timing logs (every cron tick = ~10 lines/sec)
  # from flooding /var/log/messages. These are arq's built-in cron logging.
  # The filter MUST come before the catch-all (*.* -/var/log/messages) rule.
  services.rsyslogd.defaultConfig = ''
    if $programname == 'amc-worker-start' and ($msg contains ' cron:' or $msg contains 'arq') then stop

    local1.*                     -/var/log/dhcpd
    mail.*                       -/var/log/mail
    *.=warning;*.=err            -/var/log/warn
    *.crit                        /var/log/warn
    *.*;mail.none;local1.none    -/var/log/messages
  '';

  # ── Nix GitHub App token refresh ────────────────────────────────────
  # GitHub App installation tokens expire after 1 hour.
  # This timer regenerates the token every 30 min and writes it to
  # /etc/nix/github-access-tokens.conf which nix.conf !include's.
  systemd.services.nix-github-token-refresh = {
    description = "Refresh GitHub App token for Nix daemon";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig.Type = "oneshot";
    path = [gh-token];
    script = ''
      set -euo pipefail
      TOKEN=$(gh-token)
      mkdir -p /etc/nix
      echo "access-tokens = github.com=$TOKEN" > /etc/nix/github-access-tokens.conf
      chmod 644 /etc/nix/github-access-tokens.conf
    '';
  };
  systemd.timers.nix-github-token-refresh = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "30min";
    };
  };

  # ── GitHub runner token refresh via GitHub App ──────────────────
  # The NixOS github-runner module only supports tokenFile (PAT/registration token).
  # We bridge this by generating a GitHub App installation token, then exchanging it
  # for a runner registration token (which the module's --token option expects).
  # Registration tokens expire after 1 hour; the timer refreshes every 30 min.
  systemd.services.github-runner-token-refresh = {
    description = "Refresh GitHub App token for GitHub Actions runner";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig.Type = "oneshot";
    path = [gh-token] ++ (with pkgs; [curl jq]);
    script = ''
      set -euo pipefail
      INSTALL_TOKEN=$(gh-token)
      REGISTRATION_TOKEN=$(curl -sf -X POST \
        -H "Authorization: token $INSTALL_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/ASEAN-Motor-Club/amc-server/actions/runners/registration-token" \
        | jq -r '.token')
      RUNNER_TOKEN_DIR="/var/lib/github-runner-token"
      mkdir -p "$RUNNER_TOKEN_DIR"
      echo -n "$REGISTRATION_TOKEN" > "$RUNNER_TOKEN_DIR/token"
      chmod 400 "$RUNNER_TOKEN_DIR/token"
    '';
  };
  systemd.timers.github-runner-token-refresh = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "30min";
    };
  };
  # Ensure the runner waits for a fresh token before starting
  systemd.services.github-runner-amc-peripheral-deploy = {
    after = ["github-runner-token-refresh.service"];
    wants = ["github-runner-token-refresh.service"];
    # Prevent nixos-rebuild switch from stopping the runner when its unit
    # definition changes. Without this, the deploy job running ON the runner
    # would be killed mid-deploy (exit 130 SIGINT).
    stopIfChanged = false;
  };

  # ── Data volume bind mounts ────────────────────────────────────────
  # The 99GB volume is mounted at /var/lib/data (hardware-configuration.nix).
  # Bind-mount subdirectories to their expected paths so services work
  # transparently while all heavy state lives on the volume.
  fileSystems."/var/lib/radio" = {
    device = "/var/lib/data/radio";
    options = ["bind"];
  };
  fileSystems."/var/lib/opencode" = {
    device = "/var/lib/data/opencode";
    options = ["bind"];
  };
  fileSystems."/var/lib/mod-releases" = {
    device = "/var/lib/data/mod-releases";
    options = ["bind"];
  };

  networking.hostName = "amc-peripheral";
  networking.domain = "";
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [22 80 443 8000 8008 8443 1935 1936];
    allowedUDPPorts = [1935];
    # Icecast admin UI accessible only over Tailscale
    interfaces."tailscale0".allowedTCPPorts = [8000];
  };
  networking.networkmanager.enable = true;
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJcMiNGgqQtOeACMso3CgZz2J3X8Ne8RxsZrQcsnoewU fmnxl-m2''
    ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO75UM3IHNzJKUxgABH6OHa/hxfQIoxTs+nGUtSU1TID''
    # Hermes Agent deploy key — lets the podman-hermes-agent container SSH
    # into this host (root@host.docker.internal) for privileged operations.
    # Added in the container-migration commit but never authorized on this host,
    # which silently broke host SSH. See amc-peripheral/hermes.nix.
    ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP6GMtDsVpqvPnzu4FR8Wr6lHm/Usu/eYqNpOcXKxopG hermes@amc-server''
  ];
  users.users.freeman = {
    isNormalUser = true;
    home = "/home/freeman";
    description = "Alice Foobar";
    extraGroups = ["wheel" "networkmanager"];
    openssh.authorizedKeys.keys = [''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJcMiNGgqQtOeACMso3CgZz2J3X8Ne8RxsZrQcsnoewU fmnxl-m2''];
  };
  system.stateVersion = "23.11";
  nix.settings.experimental-features = ["nix-command" "flakes"];

  # ── Automatic garbage collection ───────────────────────────────────
  # The peripheral host deploys on every push to master, accumulating NixOS
  # generations that previously filled the 52G root disk (98%), which crashed
  # PostgreSQL mid-deploy. Daily GC keeps the last 7 days of generations
  # (enough for rollback) and reclaims the rest. Store optimisation hardlink
  # -dedupes the store for further space savings.
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 7d";
  };
  nix.optimise.automatic = true;

  # ── Podman image GC ──────────────────────────────────────────────
  # The daily nix.gc never touches the podman store, which accumulated
  # ~6.5G of unused images (old hermes builds + dangling layers). Weekly
  # prune removes all images not referenced by a running container; the
  # --filter until=72h guards against racing a just-rebuilt image.
  systemd.timers.podman-image-prune = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
    };
  };
  systemd.services.podman-image-prune = {
    path = with pkgs; [podman];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.podman}/bin/podman image prune -af --filter until=72h";
    };
  };

  # ── Hermes agent data GC ─────────────────────────────────────────
  # Package-manager caches under /var/lib/hermes-agent (uv/pnpm/nix/node)
  # regrow to several GB. Weekly removal of files untouched for 7 days keeps
  # them bounded without racing a cache in active use. Never touches
  # workspace/, sessions/, memories/, config, or .env.
  systemd.timers.hermes-cache-prune = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
    };
  };
  systemd.services.hermes-cache-prune = {
    path = with pkgs; [coreutils findutils];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.findutils}/bin/find /var/lib/hermes-agent/.cache /var/lib/hermes-agent/.local/share/pnpm /var/lib/hermes-agent/.local/share/uv -type f -mtime +7 -delete";
    };
  };

  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [
      "steam"
      "steamcmd"
      "steam-original"
      "steam-unwrapped"
    ];

  environment.systemPackages = with pkgs; [
    kakoune
    htop
    ffmpeg
    libopus
    nodejs
    steamcmd
    gh-token
    git-credential-github-app
  ];

  # Many Node.js packages (kimaki, etc.) hardcode /bin/bash
  system.activationScripts.binbash = ''
    mkdir -p /bin
    ln -sf ${pkgs.bash}/bin/bash /bin/bash
  '';

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    # Only allow PFS-enabled ciphers with AES256
    sslCiphers = "AES256+EECDH:AES256+EDH:!aNULL";
    # Add the ngx_brotli module so precompressed .br static files can be
    # served (brotli_static) alongside gzip_static.
    package = pkgs.nginxStable.override {
      modules = [ pkgs.nginxModules.brotli ];
    };

    virtualHosts."www.aseanmotorclub.com" = {
      enableACME = true;
      forceSSL = true;
      locations = {
        "/" = {
          root = "/var/www/www.aseanmotorclub.com";
          tryFiles = "$uri $uri.html $uri/index.html /fallback.html";
        };
        "/_app/immutable/" = {
          root = "/var/www/www.aseanmotorclub.com";
          extraConfig = ''
            # Set a long expiry time (1 year)
            expires 1y;
            # Add the immutable cache-control header
            add_header Cache-Control "public, max-age=31536000, immutable";
            # Optional: disable access logging for static files
            access_log off;
          '';
        };
        "/map_tiles/" = {
          root = "/var/www/www.aseanmotorclub.com";
          extraConfig = ''
            # 1. CORS Headers
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, OPTIONS';

            # Serve precompressed .br twins (added by the ngx_brotli module)
            # when the client accepts brotli; gzip_static already handles .gz.
            brotli_static on;
            brotli_types application/octet-stream;

            # 2. Cache Headers (REPEATED)
            # We must repeat these because 'add_header' above clears parent headers
            expires 1y;
            add_header Cache-Control "public, max-age=31536000, immutable";

            # 3. Security Headers (REPEATED - Example)
            # If you define HSTS or other security headers in the server block,
            # you MUST repeat them here or they will be lost for tile requests.
            # add_header Strict-Transport-Security "max-age=31536000";
            access_log off;
            # 4. CORS Preflight
            if ($request_method = 'OPTIONS') {
               add_header 'Access-Control-Allow-Origin' '*';
               add_header 'Access-Control-Max-Age' 1728000;
               add_header 'Content-Type' 'text/plain; charset=utf-8';
               add_header 'Content-Length' 0;
               add_header Cache-Control "public, max-age=31536000, immutable";
               return 204;
            }
          '';
        };
        "/releases/" = {
          alias = "/var/lib/mod-releases/";
          extraConfig = ''
            autoindex on;
          '';
        };
        "/api" = {
          proxyPass = "http://asean-mt-server:9000/api";
        };
        "/admin" = {
          proxyPass = "http://asean-mt-server:9000/admin";
        };
        "/login/token" = {
          proxyPass = "http://asean-mt-server:9000/login/token";
        };
        "/stream" = {
          proxyPass = "http://127.0.0.1:8000/stream";
          extraConfig = ''
            proxy_http_version 1.1;
            proxy_connect_timeout 5s;
            proxy_read_timeout 86400s;
            proxy_send_timeout 86400s;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "keep-alive";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_buffering off;  # Disable buffering for streaming
            proxy_cache off;      # Ensure no cache is used for streaming data
            gzip off; # Don't try to compress an already compressed media stream
            access_log off; # Optional: prevent logging every chunk of the stream
            # Optionally, add the header to explicitly disable internal buffering
            add_header X-Accel-Buffering no;
          '';
        };
        "/proxy" = {
          proxyPass = "http://127.0.0.1:8001/proxy";
          extraConfig = ''
            add_header Access-Control-Allow-Origin *;
          '';
        };
        "/hls" = {
          root = "/var/lib/radio";
          extraConfig = ''
            add_header Cache-Control "no-cache";
            add_header Access-Control-Allow-Origin "*";
            types { application/vnd.apple.mpegurl m3u8; }
          '';
        };
        "/routes" = {
          root = "/srv/www";
        };
        "/stream_high" = {
          return = "301 /stream";
        };
      };
    };

    virtualHosts."legacy.aseanmotorclub.com" = {
      enableACME = true;
      locations = {
        "/" = {
          proxyPass = "http://127.0.0.1:8001/";
        };
        "/radio" = {
          proxyPass = "http://127.0.0.1:8001/radio";
        };
        "/industries" = {
          proxyPass = "http://127.0.0.1:8001/industries";
        };
        "/track/live" = {
          proxyPass = "http://127.0.0.1:8001/track/live";
        };
        "/proxy" = {
          proxyPass = "http://127.0.0.1:8001/proxy";
          extraConfig = ''
            add_header Access-Control-Allow-Origin *;
          '';
        };
        "/track" = {
          root = "/srv/www";
        };
        "/routes" = {
          root = "/srv/www";
        };
        "/hls" = {
          root = "/var/lib/radio";
        };
        "/stream" = {
          proxyPass = "http://127.0.0.1:8000/stream";
          extraConfig = ''
            proxy_http_version 1.1;
            proxy_connect_timeout 5s;
            proxy_read_timeout 86400s;
            proxy_send_timeout 86400s;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "keep-alive";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_buffering off;  # Disable buffering for streaming
            proxy_cache off;      # Ensure no cache is used for streaming data
            gzip off; # Don't try to compress an already compressed media stream
            # Optionally, add the header to explicitly disable internal buffering
            add_header X-Accel-Buffering no;
          '';
        };
        "/stream_high" = {
          return = "301 /stream";
        };
        "/stream2" = {
          proxyPass = "http://127.0.0.1:8000/stream2";
          extraConfig = ''
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "keep-alive";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_buffering off;  # Disable buffering for streaming
            proxy_cache off;      # Ensure no cache is used for streaming data
            # Optionally, add the header to explicitly disable internal buffering
            add_header X-Accel-Buffering no;
          '';
        };
        "/live" = {
          proxyPass = "http://127.0.0.1:8008/live";
          extraConfig = ''
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "keep-alive";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_buffering off;  # Disable buffering for streaming
            proxy_cache off;      # Ensure no cache is used for streaming data
            # Optionally, add the header to explicitly disable internal buffering
            add_header X-Accel-Buffering no;
          '';
        };
      };
    };
  };

  security.acme.defaults.email = "contact@fmnxl.xyz";
  security.acme.acceptTerms = true;

  # === DokuWiki ===
  age.secrets.dokuwiki-oauth = {
    file = ../../secrets/dokuwiki-oauth.age;
    mode = "400";
    owner = "dokuwiki";
  };

  services.nginx.virtualHosts."wiki.aseanmotorclub.com" = {
    enableACME = true;
    forceSSL = true;
  };

  services.dokuwiki = {
    webserver = "nginx";
    sites = let
      # DokuWiki 2026-07-14b "Mort" — the first stable release with NATIVE
      # Markdown support (PR #4636, $conf['syntax'] = dw+md). Bumping the
      # version is enough; the pinned nixpkgs's dokuwiki package.nix is just
      # `version + src`. PHP must be >= 8.2 (composer platform_check), so the
      # site's phpPackage is overridden to php83 (available in the same pin).
      dokuwiki2026 = pkgs.dokuwiki.overrideAttrs (old: {
        version = "2026-07-14b";
        src = pkgs.fetchFromGitHub {
          owner = "dokuwiki";
          repo = "dokuwiki";
          rev = "release-2026-07-14b";
          sha256 = "sha256-w/uVk60gdr4PhUMOHHYl+X87Hx9pojYqJo5sZXLUX6o=";
        };
        # The pinned nixpkgs dokuwiki carries a `backport-xss-fix-in-search.patch`,
        # but that XSS fix is ALREADY in 2026-07-14b (the patch reverses and the
        # build fails). Clear it — the fix ships with the release now.
        patches = [];
      });
      dokuwiki-plugin-infobox = pkgs.stdenv.mkDerivation {
        name = "infobox";
        src = pkgs.fetchzip {
          url = "https://github.com/Kanaru92/DokuWiki-InfoBox/archive/9e9b4c22289540b28728a8e7e16a871fa549906f.zip";
          sha256 = "sha256-N6ReTPlpN1xOQ1UkhkJa7jKnHFGUg/K3hP4kZHJY8i8=";
        };
        sourceRoot = ".";
        installPhase = "mkdir -p $out; cp -R source/* $out/;";
      };
      dokuwiki-plugin-include = pkgs.stdenv.mkDerivation {
        name = "include";
        src = pkgs.fetchzip {
          url = "https://github.com/dokufreaks/plugin-include/archive/7cc855fb1857.zip";
          sha256 = "sha256-GmcK+btsxqqMhFsZsAekmRatonhDmM6gaIiLfune5Vo=";
        };
        sourceRoot = ".";
        installPhase = "mkdir -p $out; cp -R source/* $out/;";
      };
      dokuwiki-plugin-imagebox = pkgs.stdenv.mkDerivation {
        name = "imagebox";
        src = fetchTarball {
          url = "https://github.com/flammy/imagebox/tarball/master";
          sha256 = "sha256:0ir4xavz47qhhk9xiy7rm723scygsgyhgd142js21ga0997wxsbj";
        };
        sourceRoot = ".";
        installPhase = "mkdir -p $out; cp -R source/* $out/;";
      };
      dokuwiki-plugin-oauth = pkgs.stdenv.mkDerivation {
        name = "oauth";
        src = fetchTarball {
          url = "https://github.com/cosmocode/dokuwiki-plugin-oauth/archive/refs/heads/master.tar.gz";
          sha256 = "sha256:1c0b6iwqsllk2fp2k77k4aavz84m6cfnddp51410pxlg19mf3wib";
        };
        sourceRoot = ".";
        installPhase = "mkdir -p $out; cp -R * $out/;";
      };
      dokuwiki-plugin-oauthgeneric = pkgs.stdenv.mkDerivation {
        name = "oauthgeneric";
        src = fetchTarball {
          url = "https://github.com/cosmocode/dokuwiki-plugin-oauthgeneric/archive/refs/heads/master.tar.gz";
          sha256 = "sha256:1adgw67g32rmx4byx7iamikg3krynl4pyp1yjmfwvdlmq8zxvg81";
        };
        sourceRoot = ".";
        installPhase = "mkdir -p $out; cp -R * $out/;";
      };
    in {
      "wiki.aseanmotorclub.com" = {
        package = dokuwiki2026;
        phpPackage = pkgs.php83;
        plugins = [
          dokuwiki-plugin-infobox
          dokuwiki-plugin-include
          dokuwiki-plugin-imagebox
          dokuwiki-plugin-oauth
          dokuwiki-plugin-oauthgeneric
        ];
        settings = {
          title = "ASEAN Motor Club";
          tagline = "AMC Wiki for Motor Town: Behind The Wheel";
          useacl = false;
          userewrite = true;
          updatecheck = false;
          # Native GFM markdown (DokuWiki 2026+). dw+md = DokuWiki-preferred,
          # markdown fallback — keeps existing core .txt pages rendering while
          # also rendering the new markdown memory/ pages.
          syntax = "dw+md";

          authtype = "oauth";
          plugin____oauth____registerOnAuth = true;
          plugin____oauthgeneric____key = "dokuwiki";
          plugin____oauthgeneric____secret._file = config.age.secrets.dokuwiki-oauth.path;
          plugin____oauthgeneric____authurl = "https://api.aseanmotorclub.com/o/authorize/";
          plugin____oauthgeneric____tokenurl = "https://api.aseanmotorclub.com/o/token/";
          plugin____oauthgeneric____userurl = "https://api.aseanmotorclub.com/api/users/me/";
          plugin____oauthgeneric____json_user = "user";
          plugin____oauthgeneric____json_name = "name";
          plugin____oauthgeneric____json_mail = "mail";
          plugin____oauthgeneric____json_grps = "grps";
        };
      };
    };
  };

  # === Wiki Pipeline (game data ETL → DokuWiki) ===
  age.secrets.steam = {
    file = ../../secrets/steam.age;
    mode = "400";
    owner = "root";
  };

  systemd.services.amc-wiki-download = {
    description = "Download Motor Town game PAK via steamcmd";
    path = with pkgs; [steamcmd];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "wiki-pipeline";
      WorkingDirectory = "/var/lib/wiki-pipeline";
      EnvironmentFile = config.age.secrets.steam.path;
    };
    script = ''
      set -euo pipefail
      mkdir -p /var/lib/wiki-pipeline/game

      steamcmd +@sSteamCmdForcePlatformType windows \
        +force_install_dir /var/lib/wiki-pipeline/game \
        +login "$STEAM_USERNAME" "$STEAM_PASSWORD" \
        +app_update 1369670 validate \
        +quit

      echo "Download complete"
    '';
  };

  systemd.services.amc-wiki-etl = {
    description = "Motor Town ETL: extract → aggregate → wiki sync";
    requires = ["amc-wiki-download.service"];
    after = ["amc-wiki-download.service"];
    path = with pkgs; [nix git];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "wiki-pipeline";
      WorkingDirectory = "/var/lib/wiki-pipeline";
      TimeoutStartSec = 3600;
    };
    script = ''
      set -euo pipefail

      PAK="/var/lib/wiki-pipeline/game/MotorTown/Content/Paks/MotorTown-Windows.pak"
      WORK="/var/lib/wiki-pipeline"
      SRC="$WORK/mt-pak-extract"

      if [ ! -f "$PAK" ]; then
        echo "ERROR: PAK file not found at $PAK"
        exit 1
      fi

      # Clone or update mt-pak-extract source
      echo "=== Preparing source ==="
      if [ -d "$SRC/.git" ]; then
        cd "$SRC"
        git pull --ff-only origin main || true
      else
        rm -rf "$SRC"
        git clone --recurse-submodules https://github.com/ASEAN-Motor-Club/mt-pak-extract.git "$SRC"
        # Fix SSH submodule URLs to HTTPS (no SSH keys on this host)
        cd "$SRC"
        sed -i 's|git@github.com:|https://github.com/|g' .gitmodules
        git submodule sync
        git submodule update --init --recursive || true
      fi
      ln -sf "$PAK" "$SRC/MotorTown-Windows.pak"

      echo "=== Step 1+2: Extracting assets (Rust + C#) ==="
      cd "$SRC"
      nix run "$SRC#extract"

      echo "=== Step 3: Aggregating to SQLite ==="
      MT_DB_PATH="$SRC/motortown.db" nix run "$SRC#aggregate"

      echo "=== Step 3b: Symlink gamedata.db for bot and backend ==="
      mkdir -p /var/lib/motortown
      ln -sf "$SRC/motortown.db" /var/lib/motortown/gamedata.db

      echo "=== Step 4: DokuWiki — skipped (hand-generated from beam41/mt-map-extract/wiki) ==="
      echo "  wiki_sync.py is decommissioned; the wiki page store is generated with the beam41"
      echo "  wiki pipeline (https://github.com/beam41/mt-map-extract/wiki) and published by hand."
      echo "  Do NOT re-run wiki_sync.py here — it would clobber the hand-authored pages."
      chown -R dokuwiki:nginx /var/lib/dokuwiki/wiki.aseanmotorclub.com/data/pages/

      echo "=== Pipeline complete ==="
    '';
  };

  users.users.sftpuser = {
    isNormalUser = true;
    createHome = true;
    home = "/home/sftpuser";
    group = "sftpuser";
    extraGroups = ["web-content"];
    openssh.authorizedKeys.keys = [
      (
        "command=\"${pkgs.rrsync}/bin/rrsync /var/www/www.aseanmotorclub.com\" "
        + ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJcMiNGgqQtOeACMso3CgZz2J3X8Ne8RxsZrQcsnoewU fmnxl-m2''
      )
      (
        "command=\"${pkgs.rrsync}/bin/rrsync /var/www/www.aseanmotorclub.com\" "
        + ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO7Gb+mZklKMeqGhnYZzy40Kl6k7CGNyH989jQwEqI3Q deploy''
      )
    ];
  };
  users.groups.sftpuser = {};
  users.groups.web-content = {};
  users.users.nginx.extraGroups = ["web-content"];

  systemd.tmpfiles.rules = [
    "d /var/www 0755 root root -"
    "d /var/www/www.aseanmotorclub.com 0755 sftpuser sftpuser -"
    # Ensure data volume subdirs exist before bind mounts activate
    "d /var/lib/data/radio 0755 root root -"
    "d /var/lib/data/opencode 0755 opencode opencode -"
    "d /var/lib/data/mod-releases 0775 steam modders -"
    "d /var/lib/data/amc-memory 0755 root root -"
    "d /var/lib/data/amc-memory-bot 0755 root root -"
    # OpenCode workspace directories (created on the volume via bind mount)
    "d /var/lib/opencode 0755 opencode opencode -"
    "d /var/lib/opencode/workspace 0755 opencode opencode -"
    "d /var/lib/opencode/workspace/tasks 0755 opencode opencode -"
  ];

  services.openssh.extraConfig = ''
    # Match the SFTP user group.
    Match Group sftpuser
      # Chroot the user to their home directory.
      # Disable TCP forwarding and X11 forwarding for security.
      AllowTcpForwarding no
      X11Forwarding no
  '';

  # === OpenCode Coding Agent ===
  users.users.opencode = {
    isSystemUser = true;
    group = "opencode";
    home = "/var/lib/opencode";
    createHome = true;
    shell = pkgs.bash;
  };
  users.groups.opencode = {};

  # ── Workspace sync (one-shot) ──────────────────────────────────────
  # Clones or updates the amc-server repo with submodules.
  # Run manually:  systemctl start opencode-workspace
  systemd.services.opencode-workspace = {
    description = "OpenCode – Sync amc-server workspace to latest main";
    after = ["network-online.target"];
    wants = ["network-online.target"];

    serviceConfig = {
      Type = "oneshot";
      User = "opencode";
      Group = "opencode";
      StateDirectory = "opencode";
      WorkingDirectory = "/var/lib/opencode";
    };

    environment = {
      HOME = "/var/lib/opencode";
    };

    path = with pkgs; [git openssh coreutils jq openssl curl];

    script = ''
      set -euo pipefail

      REPO_DIR="/var/lib/opencode/workspace/amc-server"

      # ── Configure git to use Nix-managed credential helper ──
      # Remove stale url.x-access-token insteadOf entries from previous config
      if [ -f "$HOME/.gitconfig" ]; then
        grep -v x-access-token "$HOME/.gitconfig" > "$HOME/.gitconfig.tmp" && mv "$HOME/.gitconfig.tmp" "$HOME/.gitconfig" || true
      fi
      git config --global credential.helper "${git-credential-github-app}/bin/git-credential-github-app"
      git config --global user.name "AMC Coding Agent[bot]"
      git config --global user.email "2922326+amc-coding-agent[bot]@users.noreply.github.com"

      # ── Clone or sync workspace ──
      if [ ! -d "$REPO_DIR/.git" ]; then
        echo "Cloning repository..."
        mkdir -p "$(dirname "$REPO_DIR")"
        git clone --recurse-submodules https://github.com/ASEAN-Motor-Club/amc-server.git "$REPO_DIR"
      else
        echo "Fetching latest..."
        cd "$REPO_DIR"
        git fetch --no-recurse-submodules origin master
        git checkout master
        git reset --hard origin/master
        git clean -fd
        # Deinit + reinit submodules to handle orphaned refs gracefully
        git submodule deinit --all -f || true
        git submodule update --init --recursive
      fi

      cd "$REPO_DIR"

      # Ensure worktrees directory exists
      mkdir -p /var/lib/opencode/workspace/worktrees

      # Deploy opencode config globally so all instances (worktrees etc.) inherit it
      mkdir -p "$HOME/.config/opencode"
      cat > "$HOME/.config/opencode/opencode.json" << 'OPENCODE_EOF'
      {
        "$schema": "https://opencode.ai/config.json",
        "provider": {
          "openrouter": {}
        },
        "model": "openrouter/deepseek/deepseek-v4-flash-0731",
        "command": {
          "pr": {
            "description": "commit, push, and create a PR from current changes",
            "agent": "build",
            "template": "Commit all changes, push the branch, and create a draft pull request.\n\n1. Stage all changes: git add -A\n2. Commit with a descriptive message based on the changes: git commit -m \"$ARGUMENTS\"\n3. Push the branch: git push -f origin HEAD\n4. Get a fresh token for the GitHub CLI: export GH_TOKEN=$(gh-token)\n5. Create a draft PR: gh pr create --repo ASEAN-Motor-Club/amc-server --base master --fill --draft\n\nIMPORTANT: You MUST run ALL of these commands. Do not skip any step."
          },
          "task": {
            "description": "create a new worktree for an isolated task",
            "agent": "build",
            "template": "Create an isolated git worktree for a new task. Follow ALL steps in order.\n\n## 1. Sync upstream\n```bash\ncd /var/lib/opencode/workspace/amc-server\ngit fetch --no-recurse-submodules origin master\ngit checkout master\ngit reset --hard origin/master\ngit submodule deinit --all -f 2>/dev/null || true\ngit submodule update --init --recursive\n```\n\n## 2. Create worktree\nSlugify the task description into a short kebab-case slug (e.g. 'fix radio queue' → 'fix-radio-queue').\n```bash\nSLUG=\"<slugified-description>\"\ngit worktree add ../tasks/$SLUG -b agent/$SLUG origin/master\ncd ../tasks/$SLUG\ngit submodule update --init --recursive\n```\n\n## 3. Report\nTell the user the worktree is ready at `/var/lib/opencode/workspace/tasks/$SLUG` and they should switch to it.\nList existing worktrees with `git worktree list`.\n\nIMPORTANT: Always create worktrees from the MAIN workspace at /var/lib/opencode/workspace/amc-server, never from another worktree."
          },
          "deploy": {
            "description": "rebase on latest master, push, and deploy to this server",
            "agent": "build",
            "template": "Safely deploy changes to this server. You MUST follow all steps in order.\n\n## Pre-deploy: Rebase on latest master\n\n1. Fetch latest from remote:\n```bash\ngit fetch --no-recurse-submodules origin master\n```\n\n2. Rebase current branch onto latest master:\n```bash\ngit rebase origin/master\n```\nIf there are conflicts, resolve them, then `git rebase --continue`. If you cannot resolve them, abort with `git rebase --abort` and report the issue.\n\n3. Update submodules to match:\n```bash\ngit submodule update --init --recursive\n```\n\n4. Push to remote (force-push since we rebased):\n```bash\ngit push -f origin HEAD\n```\n\n## Deploy\n\n5. Run nixos-rebuild directly from the current worktree:\n```bash\nsudo nixos-rebuild switch --flake .#amc-peripheral --override-input amc-peripheral ./amc-peripheral\n```\n\n6. Report the result to the user.\n\nIMPORTANT: You MUST rebase before deploying. Never skip steps 1-4. Always run nixos-rebuild from the CURRENT worktree directory, not the main workspace."
          }
        }
      }
      OPENCODE_EOF

      # Global agent rules
      cat > "$HOME/.config/opencode/AGENTS.md" << 'AGENTS_EOF'
      # AMC Coding Agent (Peripheral)

      You are running **on the amc-peripheral server itself**. Your workspace is a
      checkout of the amc-server monorepo at `/var/lib/opencode/workspace/amc-server`.

      > **IMPORTANT**: You are running locally on this host. You do NOT need SSH to
      > access services — use `systemctl`, `journalctl`, and `curl` directly.

      ## Workflow: Worktree-per-Task

      This server uses a **worktree-per-task** model. The main workspace at
      `/var/lib/opencode/workspace/amc-server` tracks upstream `master` only.
      All development happens in isolated worktrees.

      ### Creating a task
      ```
      /task fix the radio queue ordering
      ```
      This creates a worktree at `tasks/<slug>/` branched from latest master.

      ### Finishing a task
      ```
      /pr description of changes
      ```
      This commits, pushes, and creates a draft PR.

      ### Deploying
      ```
      /deploy
      ```
      This rebases onto latest master, pushes, and runs
      `nixos-rebuild switch --flake .#amc-peripheral` directly from the worktree.

      > **CAUTION**: NEVER edit the main workspace directly. Always use `/task`
      > to create an isolated worktree first.

      ### Managing worktrees
      ```bash
      git -C /var/lib/opencode/workspace/amc-server worktree list
      git -C /var/lib/opencode/workspace/amc-server worktree remove tasks/<slug>
      ```

      ## Services on This Host

      | Service | Unit | Description |
      |---------|------|-------------|
      | Radio bots | `amc-radio` | Liquidsoap radio + Discord bots |
      | Fallback stream | `fallback` | Fallback radio stream |
      | Discord bots | `amc-bot` | Discord bots |
      | Kimaki | `kimaki` | Discord↔OpenCode bridge (Jarvis) — spawns its own opencode serve on port 33405 |
      | Nginx | `nginx` | Reverse proxy for all web services |
      | Tailscale | `tailscale` | VPN for SSH access |
      | OAuth2 Proxy | `oauth2-proxy` | GitHub auth for web UI (port 4180) |

      ### Check service status
      ```bash
      systemctl status amc-radio amc-bot kimaki nginx
      ```

      ### View logs
      ```bash
      journalctl -u amc-radio -n 100 --no-pager
      journalctl -u amc-radio --since '1 hour ago' --no-pager
      ```

      ### Restart a service
      ```bash
      systemctl restart amc-radio
      ```

      ## NixOS Configuration

      - `machines/amc-peripheral/configuration.nix` — main machine config
      - `flake.nix` — flake wiring, secrets, overlays
      - `amc-peripheral/` — submodule with the radio/bot Python package
      - `secrets/secrets.nix` — ragenix secret definitions

      ## GitHub Authentication

      All GitHub access uses the **GitHub App** (`asean-coding-agent[bot]`).
      There is no static PAT — tokens are generated on demand and expire after 1 hour.

      - **Git push/pull**: Automatic — `git-credential-github-app` is the global credential helper.
      - **GitHub CLI** (`gh pr create`, etc.): Run `export GH_TOKEN=$(gh-token)` first.
      - **Nix fetches**: Automatic — a systemd timer (`nix-github-token-refresh`) refreshes the token every 30 min.

      If Nix builds fail with "Bad credentials" or 401 errors on GitHub fetches:
      ```bash
      sudo systemctl start nix-github-token-refresh
      ```
      Do NOT suggest creating or regenerating a PAT — the GitHub App handles everything.

      ## Production Database Access

      You have **read-only** access to the production database on `asean-mt-server`
      via Tailscale. Use `psql` with the `BACKEND_DB_URL` environment variable:

      ```bash
      # Query production DB (always use the full connection string)
      psql "$BACKEND_DB_URL" -c "SELECT name, balance FROM amc_player LIMIT 10"
      psql "$BACKEND_DB_URL" -c "\d amc_player"

      # Expanded output for wide rows
      psql "$BACKEND_DB_URL" -c "\\x" -c "SELECT * FROM amc_player WHERE id = 1"
      ```

      > **IMPORTANT**: Always use `psql "$BACKEND_DB_URL"` — never bare `psql`.
      > The `PGHOST`/`PGUSER` env vars point to the LOCAL staging database,
      > not production. Using bare `psql` would connect to the wrong database.

      **Security**: The `amc_bot_reader` user is SELECT-only. Finance tables
      (`amc_finance_account`, `amc_finance_ledgerentry`, `amc_finance_journalentry`)
      are blocked by Row-Level Security. Any write attempt will fail.

      ## Architecture Notes

      - This server does **NOT** run the game server or Django backend
      - The Django backend runs on `asean-mt-server` (a separate host)
      - The `amc-peripheral` Python package (radio bots, Discord bots) is in
        the `amc-peripheral/` submodule

      ## Development Tools (Nix Flakes)

      This monorepo uses **Nix flakes** to provide all development tools.
      Python, pytest, ruff, and other tools are **NOT** installed globally —
      they are only available inside nix devShells.

      A **staging PostgreSQL** instance with PostGIS is running at `/run/postgresql`.
      The `PGHOST` and `PGUSER` env vars point to this local staging database.
      This is SEPARATE from the production database on `asean-mt-server` (see below).

      ### Running tests

      Use `nix develop` to enter a devShell with Python, pytest, and all
      dependencies. pytest-django creates a temporary test database
      (`test_amc`) automatically — no manual `migrate` needed:

      ```bash
      # Run specific tests
      nix develop ./amc-backend --override-input amc-backend ./amc-backend -c bash -c '
        python -m pytest src/amc/test_criminals.py -v --tb=short
      '

      # Run the full suite
      nix develop ./amc-backend --override-input amc-backend ./amc-backend -c bash -c '
        python -m pytest src/ --tb=short -q
      '
      ```

      Alternatively, `nix flake check` runs the full suite in an **isolated
      sandbox** with its own temporary Postgres (slower but fully self-contained):

      ```bash
      nix flake check ./amc-backend -L --override-input amc-backend ./amc-backend
      ```

      Lint and type check (no database needed):

      ```bash
      nix flake check ./amc-backend#ruff --override-input amc-backend ./amc-backend
      nix flake check ./amc-backend#pyrefly --override-input amc-backend ./amc-backend
      ```

      ### Important

      - Always run Python/pytest inside `nix develop ./amc-backend` so the
        correct virtualenv and native libraries (GEOS, GDAL, PostGIS) are available.
      - Do **NOT** use `pip install` or `uv sync` directly — the Nix devShell
        manages the Python environment via uv2nix.
      - When running in a worktree, pass `--override-input` to point at the
        local submodule checkout.
      - pytest-django handles test database creation/deletion. Do NOT run
        `migrate` against the main `amc` database — it's used by the staging
        backend. Tests use `test_amc` which pytest-django manages automatically.
      AGENTS_EOF

      echo "Workspace ready at $REPO_DIR"
    '';
  };

  # ── Kimaki (Discord↔OpenCode bridge) ───────────────────────────────
  # Replaces the old amc-jarvis bot. Uses the Jarvis Discord bot token
  # to bridge Discord messages directly into OpenCode coding sessions.
  # Kimaki spawns its own opencode serve on port 33405.
  systemd.services.kimaki = {
    description = "Kimaki – Discord↔OpenCode Bridge";
    after = ["network-online.target" "opencode-workspace.service"];
    wants = ["network-online.target" "opencode-workspace.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "simple";
      User = "opencode";
      Group = "opencode";
      WorkingDirectory = "/var/lib/opencode/workspace/amc-server";
      EnvironmentFile = [
        config.age.secrets.peripheral-bots.path
        config.age.secrets.opencode-peripheral.path
      ];
      Restart = "on-failure";
      RestartSec = 10;
    };

    environment = {
      PGHOST = "/run/postgresql";
      PGUSER = "amc";
      REDIS_PORT = "6379";
      GEOS_LIBRARY_PATH = "${pkgs.geos}/lib/libgeos_c.so";
      GDAL_LIBRARY_PATH = "${pkgs.gdal}/lib/libgdal.so";
    };

    path = with pkgs; [opencode bun bash git openssh gh coreutils nodejs unzip which nix direnv postgresql];

    script = ''
      set -euo pipefail

      # Kimaki uses KIMAKI_BOT_TOKEN env var for the Discord bot token.
      # DISCORD_TOKEN_DEV comes from peripheral-bots.env
      export KIMAKI_BOT_TOKEN="$DISCORD_TOKEN_DEV"

      # Data directory for kimaki state (SQLite DB, logs)
      KIMAKI_DIR="/var/lib/opencode/.kimaki"
      mkdir -p "$KIMAKI_DIR"

      exec ${(import ../../nix/kimaki {inherit pkgs;}).package}/bin/kimaki --data-dir "$KIMAKI_DIR"
    '';
  };

  # ── Task runner (worktree-per-task) ────────────────────────────────
  # Template service: systemctl start "opencode-task@<task-id>"
  # Task prompt is read from /var/lib/opencode/tasks/<task-id>/prompt.txt
  systemd.services."opencode-task@" = {
    description = "OpenCode – Run task %i";
    after = ["network-online.target"];
    wants = ["network-online.target"];

    serviceConfig = {
      Type = "oneshot";
      User = "opencode";
      Group = "opencode";
      StateDirectory = "opencode";
      WorkingDirectory = "/var/lib/opencode/workspace/amc-server";
      TimeoutStartSec = "30min";
      EnvironmentFile = config.age.secrets.opencode-peripheral.path;
    };

    environment = {
      HOME = "/var/lib/opencode";
      PGHOST = "/run/postgresql";
      PGUSER = "amc";
      REDIS_PORT = "6379";
      GEOS_LIBRARY_PATH = "${pkgs.geos}/lib/libgeos_c.so";
      GDAL_LIBRARY_PATH = "${pkgs.gdal}/lib/libgdal.so";
    };

    path = with pkgs; [git openssh gh coreutils jq openssl curl nix opencode] ++ [git-credential-github-app gh-token];

    script = ''
      set -euo pipefail

      TASK_ID="%i"
      TASK_DIR="/var/lib/opencode/tasks/$TASK_ID"
      REPO_DIR="/var/lib/opencode/workspace/amc-server"
      WORKTREE_BASE="/var/lib/opencode/workspace/worktrees"

      # Read task prompt
      if [ ! -f "$TASK_DIR/prompt.txt" ]; then
        echo "ERROR: No prompt file at $TASK_DIR/prompt.txt"
        exit 1
      fi
      TASK_DESCRIPTION=$(cat "$TASK_DIR/prompt.txt")

      # Git credential helper is deployed by opencode-workspace service.
      # It generates fresh GitHub App tokens on every git operation.

      # Write auth.json
      mkdir -p "$HOME/.local/share/opencode"
      echo "{\"openrouter\":{\"apiKey\":\"$OPENROUTER_API_KEY\"}}" \
        | jq . > "$HOME/.local/share/opencode/auth.json"

      # Derive branch name from task ID
      BRANCH_NAME="agent/$TASK_ID"

      cd "$REPO_DIR"
      git fetch origin master

      # Create isolated worktree
      WORKTREE_PATH="$WORKTREE_BASE/$TASK_ID"
      mkdir -p "$WORKTREE_BASE"
      git worktree add "$WORKTREE_PATH" -b "$BRANCH_NAME" origin/master

      cd "$WORKTREE_PATH"
      git config user.name "AMC Coding Agent[bot]"
      git config user.email "2922326+amc-coding-agent[bot]@users.noreply.github.com"

      # Run the coding agent in the worktree
      opencode run "$TASK_DESCRIPTION"

      # Check if any changes were made
      if git diff --quiet && git diff --cached --quiet; then
        echo "No changes made by agent"
        echo "no_changes" > "$TASK_DIR/result.txt"
        exit 0
      fi

      # Stage and commit
      git add -A
      if ! git diff --cached --quiet; then
        git commit -m "agent: $TASK_ID"
      fi

      # Push the branch
      git push -f origin "$BRANCH_NAME"

      # Get fresh token for gh CLI
      export GH_TOKEN=$(${gh-token}/bin/gh-token)

      # Create draft PR
      PR_URL=$(gh pr create \
        --repo ASEAN-Motor-Club/amc-server \
        --base master \
        --title "agent: $(echo "$TASK_DESCRIPTION" | head -c 72)" \
        --body "## Changes by Coding Agent

      Task: \`$TASK_ID\`

      ### Description
      $TASK_DESCRIPTION

      ---
      *This PR was created automatically by the AMC Coding Agent.*" \
        --draft 2>&1) || true

      echo "$PR_URL" > "$TASK_DIR/result.txt"
      echo "Task complete. Result: $PR_URL"
    '';
  };

  # ── Self-deploy service ────────────────────────────────────────────
  # Root-owned oneshot that syncs workspace and runs nixos-rebuild switch.
  # Triggered by: sudo systemctl start amc-peripheral-deploy
  systemd.services.amc-peripheral-deploy = {
    description = "Self-deploy – nixos-rebuild from latest main";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    # Prevent switch-to-configuration from restarting this service mid-deploy.
    restartIfChanged = false;

    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "30min";
    };

    environment = {
      HOME = "/var/lib/opencode";
      GITHUB_APP_ID = "2922326";
      GITHUB_INSTALLATION_ID = "111712229";
    };

    path = with pkgs; [git openssh nix coreutils jq curl systemd util-linux openssl];

    script = ''
      set -euo pipefail

      REPO_DIR="/var/lib/opencode/workspace/amc-server"
      RESULT_FILE="/var/lib/opencode/deploy-result.json"

      echo '{"status": "running", "step": "starting"}' > "$RESULT_FILE"
      chown opencode:opencode "$RESULT_FILE"

      log_step() {
        echo "$1"
        echo "{\"status\": \"running\", \"step\": \"$1\"}" > "$RESULT_FILE"
      }

      # --- GitHub App token ---
      APP_KEY="${config.age.secrets.coding-agent-app-key.path}"
      NOW=$(date +%s)
      IAT=$((NOW - 60))
      EXP=$((NOW + 600))

      b64url() { openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }
      HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | b64url)
      PAYLOAD=$(echo -n "{\"iat\":$IAT,\"exp\":$EXP,\"iss\":\"$GITHUB_APP_ID\"}" | b64url)
      SIGNATURE=$(echo -n "$HEADER.$PAYLOAD" | openssl dgst -sha256 -sign "$APP_KEY" | b64url)
      JWT="$HEADER.$PAYLOAD.$SIGNATURE"

      RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bearer $JWT" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/$GITHUB_INSTALLATION_ID/access_tokens")

      GH_TOKEN=$(echo "$RESPONSE" | jq -r '.token')
      if [ "$GH_TOKEN" = "null" ] || [ -z "$GH_TOKEN" ]; then
        echo '{"status": "failed", "step": "github-auth", "error": "Failed to get token"}' > "$RESULT_FILE"
        exit 1
      fi

      # ── Step 1: Sync workspace ──
      log_step "Syncing workspace to latest main"
      export GIT_CONFIG_COUNT=3
      export GIT_CONFIG_KEY_0=safe.directory
      export GIT_CONFIG_VALUE_0="$REPO_DIR"
      export GIT_CONFIG_KEY_1="url.https://x-access-token:$GH_TOKEN@github.com/.insteadOf"
      export GIT_CONFIG_VALUE_1="https://github.com/"
      export GIT_CONFIG_KEY_2="url.https://x-access-token:$GH_TOKEN@github.com/.insteadOf"
      export GIT_CONFIG_VALUE_2="git@github.com:"

      runuser -u opencode -- git -C "$REPO_DIR" fetch origin master
      runuser -u opencode -- git -C "$REPO_DIR" checkout master
      runuser -u opencode -- git -C "$REPO_DIR" reset --hard origin/master
      runuser -u opencode -- git -C "$REPO_DIR" clean -fd
      # Initialize top-level submodules only (not recursive) — nested
      # submodules may have unpushed commits. nixos-rebuild uses flake.lock
      # for inputs, not git submodules.
      runuser -u opencode -- git -C "$REPO_DIR" submodule update --init

      COMMIT_SHA=$(git -C "$REPO_DIR" rev-parse --short HEAD)
      COMMIT_MSG=$(git -C "$REPO_DIR" log -1 --format=%s)

      # ── Step 2: NixOS rebuild ──
      # Build first (fails on actual build errors), then switch
      # (tolerates service activation failures like amc-bot SIGSEGV).
      log_step "Building NixOS configuration"
      HOME=/root /run/current-system/sw/bin/nixos-rebuild build --flake "$REPO_DIR#amc-peripheral" 2>&1 || {
        echo "{\"status\": \"failed\", \"step\": \"nixos-rebuild\", \"error\": \"build failed\"}" > "$RESULT_FILE"
        exit 1
      }

      log_step "Switching to new configuration"
      HOME=/root /run/current-system/sw/bin/nixos-rebuild switch --flake "$REPO_DIR#amc-peripheral" 2>&1 || true

      echo "{\"status\": \"success\", \"commit\": \"$COMMIT_SHA\", \"commit_msg\": \"$COMMIT_MSG\"}" > "$RESULT_FILE"
      echo "✅ Deploy complete: $COMMIT_SHA ($COMMIT_MSG)"
    '';
  };

  # ── Sudoers: opencode can deploy via nixos-rebuild and restart services ──
  security.sudo.extraRules = [
    {
      users = ["opencode"];
      commands = [
        {
          command = "/run/current-system/sw/bin/nixos-rebuild switch *";
          options = ["NOPASSWD"];
        }
        {
          command = "/run/current-system/sw/bin/systemctl restart amc-radio amc-bot kimaki";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];

  # ── oauth2-proxy: GitHub authentication for OpenCode web UI ────────
  services.oauth2-proxy = {
    enable = true;
    httpAddress = "http://127.0.0.1:4180";
    reverseProxy = true;
    upstream = "http://127.0.0.1:4097";
    provider = "github";
    github.org = "ASEAN-Motor-Club";
    cookie.domain = "code-peripheral.aseanmotorclub.com";
    cookie.secure = true;
    email.domains = ["*"];
    setXauthrequest = true;
    extraConfig = {
      skip-provider-button = "true";
    };
    keyFile = config.age.secrets.oauth2-proxy-peripheral.path;
  };

  # ── Nginx vhost for OpenCode web UI ────────────────────────────────
  services.nginx.virtualHosts."code-peripheral.aseanmotorclub.com" = {
    enableACME = true;
    forceSSL = true;

    # Discord Activity wrapper (code-web static build)
    # Uses stable symlink to avoid nginx reload on package rebuild
    locations."/" = {
      root = "/var/www/nix-static/code-web";
      tryFiles = "$uri $uri/index.html /index.html";
      extraConfig = ''
        add_header Cache-Control "public, max-age=3600";
      '';
    };

    # OpenCode web UI behind oauth2-proxy (loaded in iframe by the Activity)
    locations."/opencode/" = {
      proxyPass = "http://127.0.0.1:4180/";
      extraConfig = ''
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
      '';
    };
  };

  services.tailscale = {
    enable = true;
  };
}
