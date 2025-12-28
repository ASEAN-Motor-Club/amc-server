{ lib, pkgs, config, ... }: {
  imports = [
    ./hardware-configuration.nix
  ];

  boot.tmp.cleanOnBoot = true;
  networking.hostName = "amc-peripheral";
  networking.domain = "";
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [22 80 443 8000 8008 1935 1936];
    allowedUDPPorts = [1935];
  };
  networking.networkmanager.enable = true;
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJcMiNGgqQtOeACMso3CgZz2J3X8Ne8RxsZrQcsnoewU fmnxl-m2''
    ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO75UM3IHNzJKUxgABH6OHa/hxfQIoxTs+nGUtSU1TID''
  ];
  users.users.freeman = {
    isNormalUser  = true;
    home  = "/home/freeman";
    description  = "Alice Foobar";
    extraGroups  = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJcMiNGgqQtOeACMso3CgZz2J3X8Ne8RxsZrQcsnoewU fmnxl-m2'' ];
  };
  system.stateVersion = "23.11";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  environment.systemPackages = with pkgs; [
    kakoune
    htop
    ffmpeg
    libopus
  ];

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    # Only allow PFS-enabled ciphers with AES256
    sslCiphers = "AES256+EECDH:AES256+EDH:!aNULL";
    

    virtualHosts."www.aseanmotorclub.com" = {
      enableACME = true;
      locations = {
        "/" = {
          root = "/var/www/www.aseanmotorclub.com";
          tryFiles = "$uri $uri.html $uri/index.html /fallback.html";
        };
        "~* \\.(?:css|js|ico|gif|jpg|jpeg|png|svg|webp|woff|woff2)$" = {
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
        "/api" = {
          proxyPass = "http://asean-mt-server:9000/api";
        };
        "/login/token" = {
          proxyPass = "http://asean-mt-server:9000/login/token";
        };
        "/stream" = {
          proxyPass = "http://127.0.0.1:8000/stream";
          extraConfig = ''
            proxy_http_version 1.1;
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
        "/routes" = {
          root = "/srv/www";
        };
        "/stream_high" = {
          proxyPass = "http://127.0.0.1:8000/stream";
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
        "/stream_high" = {
          proxyPass = "http://127.0.0.1:8000/stream";
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

  services.icecast = {
    enable = true;
    hostname = "aseanmotorclub.com";
    admin.password = "aseanmotorclub1234";  # Admin password
    
    # Bind to localhost only since Nginx will proxy
    listen.address = "0.0.0.0";
    listen.port = 8000;
    
    # Additional Icecast settings
    extraConf = ''
      <location>ASEAN Motor Club</location>
      <admin>admin@aseanmotorclub.com</admin>
      
      <limits>
        <clients>100</clients>
        <sources>2</sources>
        <queue-size>524288</queue-size>
        <client-timeout>30</client-timeout>
        <header-timeout>15</header-timeout>
        <source-timeout>10</source-timeout>
        <burst-on-connect>1</burst-on-connect>
        <burst-size>128000</burst-size>
      </limits>
      
      <mount>
        <mount-name>/stream</mount-name>
        <username>source</username>
        <password>hackme</password>
        <max-listeners>100</max-listeners>
        <public>1</public>
        <stream-name>ASEAN Motor Club Radio</stream-name>
        <stream-description>Your home for automotive enthusiasm in Southeast Asia</stream-description>
        <stream-url>https://aseanmotorclub.com/radio</stream-url>
        <genre>Automotive</genre>
        <fallback-mount>/fallback</fallback-mount>
        <fallback-override>1</fallback-override>
      </mount>

      <mount>
        <mount-name>/stream_high</mount-name>
        <username>source</username>
        <password>hackme</password>
        <max-listeners>100</max-listeners>
        <public>1</public>
        <stream-name>ASEAN Motor Club Radio</stream-name>
        <stream-description>Your home for automotive enthusiasm in Southeast Asia</stream-description>
        <stream-url>https://aseanmotorclub.com/radio_high</stream-url>
        <genre>Automotive</genre>
        <fallback-mount>/fallback</fallback-mount>
        <fallback-override>1</fallback-override>
      </mount>

      <mount>
        <mount-name>/fallback</mount-name>
        <hidden>1</hidden>
      </mount>
    '';
  };

  users.users.sftpuser = {
    isNormalUser = true;
    createHome = true;
    home = "/home/sftpuser";
    group = "sftpuser";
    extraGroups = [ "web-content" ];
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
  users.users.nginx.extraGroups = [ "web-content" ];

  systemd.tmpfiles.rules = [
    "d /var/www 0755 root root -"
    "d /var/www/www.aseanmotorclub.com 0755 sftpuser sftpuser -"
  ];

  services.openssh.extraConfig = ''
    # Match the SFTP user group.
    Match Group sftpuser
      # Chroot the user to their home directory.
      # Disable TCP forwarding and X11 forwarding for security.
      AllowTcpForwarding no
      X11Forwarding no
  '';

  services.liquidsoap.streams = {
    radio = pkgs.writeText "radio.liq" ''
      log.level := 5
      server.telnet()
      default_playlist = single("");
      settings.encoder.metadata.export := ["filename", "artist", "title", "album", "genre", "date", "tracknumber", "comment", "track", "year", "dj", "next", "apic", "metadata_url", "metadata_block_picture", "coverart"]
      queue = request.queue(id="song_requests")

      race_mode = interactive.bool("race_mode", false)
      event_mode = interactive.bool("event_mode", false)
      live = input.rtmp("rtmp://0.0.0.0:1936/live/abc123")
      announcements = request.queue(id="announcements")

      jingles = playlist(reload_mode="watch", "/var/lib/radio/jingles")
      talkshows = mksafe(
        playlist(
          reload=1,
          reload_mode="rounds",
          "/var/lib/radio/playlist/playlist.txt"
        )
      )
      def insert_intro(a, b)
        if b.metadata["intro"] != "" then
          sequence([
            a.source,
            (sequence(merge=true, [
              (once(single(b.metadata["intro"])):source),
              b.source
            ]):source)
          ])
        else
          sequence([a.source, b.source])
        end
      end

      # songs = playlist(reload_mode="watch", "/var/lib/radio/songs")
      songs = playlist("/var/lib/radio/prev_requests")
      # songs = random(weights=[1, 2], [songs, prev_requests])
      q_or_songs = fallback(track_sensitive=true, [queue, songs])
      q_or_songs = q_or_songs

      event_songs = crossfade(playlist(reload_mode="watch", "/var/lib/radio/event_songs"))

      event_jingles = playlist("/var/lib/radio/event_jingles")
      event_jingles = delay(180., event_jingles)

      race_songs = crossfade(playlist(reload_mode="watch", "/var/lib/radio/race_songs"))
      talkshows_or_jingles = rotate(weights=[1, 2], [talkshows, jingles])
      prog = rotate(weights=[1,1,3], [
        talkshows_or_jingles,
        blank(duration=2.0),
        q_or_songs,
      ])
      prog = cross(insert_intro, prog)

      radio_unnormaliszed = fallback(
        track_sensitive=false,
        [prog, default_playlist]
      )

      live = blank.strip(max_blank=2., min_noise=.1, threshold=-20., live)

      radio = nrj(normalize(radio_unnormaliszed))

      radio = switch(
        track_sensitive=false,
        [
          (race_mode, smooth_add(duration=0.5, special=live, normal=smooth_add(duration=0.5, special=announcements, normal=race_songs))),
          (event_mode, radio_unnormaliszed),
          ({true}, radio)
        ]
      )

      radio = fallback(
        track_sensitive=false,
        [radio, default_playlist]
      )

      last_metadata = ref([])
      q_or_songs.on_track(fun (m) -> last_metadata := m)
      def show_metadata(_)
        http.response(
          content_type="application/json; charset=UTF-8",
          data=metadata.json.stringify(last_metadata())
        )
      end
      harbor.http.register.simple(port=6001, "/metadata", show_metadata)

      radio = source.drop.metadata(radio)


      output.icecast(
        %mp3(bitrate=128),
        radio,
        host = "localhost",
        port = 8000,
        password = "hackme",
        mount = "/stream"
      )
      output.icecast(
        %opus,
        radio,
        host = "localhost",
        port = 8000,
        password = "hackme",
        mount = "/stream_high"
      )
    '';
    fallback = pkgs.writeText "fallback.liq" ''
      output.icecast(
        %mp3(bitrate=128),
        blank(),
        host = "localhost",
        port = 8000,
        password = "hackme",
        mount = "/fallback"
      )
    '';
  };

  services.tailscale = {
    enable = true;
  };

}
