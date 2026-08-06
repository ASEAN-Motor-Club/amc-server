{
  config,
  pkgs,
  ...
}: let
  # Pinned upstream git revision for reproducible builds.
  # Update this string and re-deploy to build a new Hermes image.
  # Use a branch name (e.g. "main") or a commit hash.
  hermesRev = "v2026.6.5";

  # ── GitHub App (asean-coding-agent[bot]) ────────────────────────────
  # Reused from the opencode agent. Gives Hermes push access + `gh` (PRs,
  # Actions) with auto-refreshing 1h installation tokens. The App key is
  # mounted into the container at /opt/data/.github-app-key; the helpers
  # below generate JWTs signed with it and exchange them for tokens.
  githubAppId = "2922326";
  githubInstallationId = "111712229";

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
    SIGNATURE=$(echo -n "$HEADER.$PAYLOAD" | ${pkgs.openssl}/bin/openssl dgst -sha256 -sign /opt/data/.github-app-key | b64url)
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
    SIGNATURE=$(echo -n "$HEADER.$PAYLOAD" | ${pkgs.openssl}/bin/openssl dgst -sha256 -sign /opt/data/.github-app-key | b64url)
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
  # ── Podman (OCI runtime) ─────────────────────────────────────────────
  virtualisation.podman = {
    enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };
  virtualisation.oci-containers.backend = "podman";

  # ── Dedicated system user ────────────────────────────────────────────
  # UID/GID must match the container's hermes user (10000:10000) so the
  # volume-mounted /var/lib/hermes-agent is traversable by the process
  # inside the container.  Without this, the container (UID 10000) cannot
  # create or modify files in directories owned by the host user.
  users.groups.hermes = {gid = 10000;};
  users.users.hermes = {
    isSystemUser = true;
    uid = 10000;
    group = "hermes";
    home = "/var/lib/hermes-agent";
    createHome = false; # managed by tmpfiles below
    shell = pkgs.bash;
  };

  # ── Persistent state ─────────────────────────────────────────────────
  # Single catch-all volume: /var/lib/hermes-agent → /opt/data (= $HERMES_HOME).
  # This matches the upstream Dockerfile/docker-compose pattern:
  #   VOLUME [ "/opt/data" ]
  #   volumes: - ~/.hermes:/opt/data
  # Every file Hermes writes under $HERMES_HOME (state.db, discord_threads.json,
  # auth.json, kanban.db, sessions/, skills/, etc.) is persisted automatically.
  # No need to enumerate individual files — any new state file Hermes adds in
  # a future version just works.
  systemd.tmpfiles.rules = [
    # Host-side symlink for git alternates compatibility.
    "L /opt/data 0755 root root - /var/lib/hermes-agent"
    "d /var/lib/hermes-agent           0750 hermes hermes -"
    # .env must pre-exist for the individual bind mount to work
    "f /var/lib/hermes-agent/.env      0640 hermes hermes -"
    # Nanobot shared knowledge base (FAQ, platform docs)
    "d /opt/nanobot                     0755 hermes hermes -"
    "d /opt/nanobot/shared-skills       0755 hermes hermes -"
  ];

  # ── Ragenix secrets ──────────────────────────────────────────────────
  age.secrets.hermes-env = {
    file = ../../secrets/hermes-env.age;
    mode = "440";
    owner = "hermes";
    group = "hermes";
  };
  age.secrets.hermes-deploy-key = {
    file = ../../secrets/hermes-deploy-key.age;
    mode = "400";
    owner = "root"; # read by ExecStartPre (runs as root)
    group = "root";
  };
  # GitHub App private key (asean-coding-agent[bot]) — same .age as the
  # opencode agent's coding-agent-app-key, decrypted to a hermes-owned path.
  age.secrets.hermes-github-app-key = {
    file = ../../secrets/coding-agent-app-key.age;
    mode = "440";
    owner = "hermes";
    group = "hermes";
  };

  # ── Image build service ──────────────────────────────────────────────
  # One-shot service that builds the Hermes OCI image from a pinned upstream rev.
  # NOT in the boot chain — triggered on-demand by podman-hermes-agent's ExecStartPre.
  # Skips rebuild if the image already exists for the pinned rev.
  systemd.services.hermes-image-build = {
    description = "Build Hermes Agent container image from pinned upstream rev";
    path = with pkgs; [git podman coreutils bash python3];
    after = ["network-online.target"];
    wants = ["network-online.target"];

    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "60min";
      User = "root";
    };

    script = ''
            set -euo pipefail

            REV="${hermesRev}"
            REV_FILE="/var/lib/hermes-agent/.hermes-rev"
            IMAGE_TAG="hermes-agent:local"
            # Bump this when the Dockerfile.slim changes force a rebuild
            # even if the upstream rev hasn't changed.
            DOCKERFILE_VERSION="3"
            BUILD_KEY="$REV:$DOCKERFILE_VERSION"

            # Check if we already have an image built for this rev+dockerfile combo
            if [ -f "$REV_FILE" ] && [ "$(cat "$REV_FILE")" = "$BUILD_KEY" ]; then
              if podman images "$IMAGE_TAG" --format "{{.Repository}}:{{.Tag}}" | grep -q "$IMAGE_TAG"; then
                echo "[hermes-image-build] Image already up-to-date for $BUILD_KEY, skipping build."
                exit 0
              fi
            fi

            echo "[hermes-image-build] Building image for $BUILD_KEY..."

            WORK=$(mktemp -d)
            trap 'rm -rf "$WORK"' EXIT

            echo "[hermes-image-build] Cloning hermes-agent at rev $REV..."
            # Try shallow clone of branch/tag first; fall back to full clone for arbitrary commits
            if ! git clone --depth 1 --branch "$REV" \
                 https://github.com/NousResearch/hermes-agent.git \
                 "$WORK/hermes" 2>/dev/null; then
              echo "[hermes-image-build] Shallow clone failed; falling back to full clone..."
              rm -rf "$WORK/hermes"
              git clone https://github.com/NousResearch/hermes-agent.git "$WORK/hermes"
              git -C "$WORK/hermes" checkout "$REV"
            fi

            # Vacuum logs before build (safe — doesn't touch images).
            journalctl --vacuum-size=300M 2>/dev/null || true

            # Use slim Dockerfile (skips Playwright/Chromium)
            cat > "$WORK/hermes/Dockerfile.slim" << 'SLIM'
      FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie AS uv_source
      FROM tianon/gosu:1.19-trixie AS gosu_source
      FROM debian:13.4
      ENV PYTHONUNBUFFERED=1
      ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright
      RUN apt-get update && \
          apt-get install -y --no-install-recommends \
              build-essential curl nodejs npm python3 ripgrep ffmpeg gcc python3-dev libffi-dev procps git openssh-client tini \
              libnss3 libnspr4 libcups2 libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 \
              libxcomposite1 libxdamage1 libxtst6 libxrandr2 libgbm1 libdrm2 libxkbcommon0 \
              libasound2t64 libpango-1.0-0 libcairo2 && \
          rm -rf /var/lib/apt/lists/*
      RUN useradd -u 10000 -m -d /opt/data hermes
      COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/
      COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/
      COPY . /opt/hermes
      WORKDIR /opt/hermes
      RUN npm install --prefer-offline --no-audit && \
          cd /opt/hermes/scripts/whatsapp-bridge && \
          npm install --prefer-offline --no-audit && \
          npm cache clean --force
      RUN chown -R hermes:hermes /opt/hermes
      USER hermes
      RUN uv venv && uv pip install --no-cache-dir -e ".[all]"
      ENV HERMES_HOME=/opt/data
      ENV PATH="/opt/hermes/.venv/bin:''${PATH}"
      VOLUME [ "/opt/data" ]
      ENTRYPOINT [ "/usr/bin/tini", "-g", "--" ]
      SLIM

            echo "[hermes-image-build] Building slim image..."
            podman build \
              -f "$WORK/hermes/Dockerfile.slim" \
              --tag "$IMAGE_TAG" \
              --tag "hermes-agent:$(date +%Y%m%d)" \
              "$WORK/hermes"

            # Record the build key (rev + dockerfile version) we just built
            echo "$BUILD_KEY" > "$REV_FILE"
            chown hermes:hermes "$REV_FILE"

            # Prune dangling images AFTER successful build to reclaim space
            # without destroying the layer cache for next time.
            podman image prune -f || true

            echo "[hermes-image-build] Build complete."
    '';
  };

  # ── OCI container ────────────────────────────────────────────────────
  virtualisation.oci-containers.containers.hermes-agent = {
    image = "hermes-agent:local";
    autoStart = true;

    volumes = [
      "/var/lib/hermes-agent:/opt/data"
      # SSH + git config (written by ExecStartPre, read-only at runtime)
      "/var/lib/hermes-agent/.ssh:/opt/data/.ssh"
      "/var/lib/hermes-agent/.gitconfig:/opt/data/.gitconfig"
      # Environment (written by ExecStartPost ragenix sync, read by container)
      "/var/lib/hermes-agent/.env:/opt/data/.env"
      # System sockets (no host permission impact)
      "/run/podman/podman.sock:/run/podman.sock:ro"
      "/run/postgresql:/run/postgresql"
      "/var/run/tailscale/tailscaled.sock:/var/run/tailscale/tailscaled.sock:ro"
      "/nix:/nix:ro"
      "/opt/nanobot/shared-skills:/opt/nanobot/shared-skills:ro"
      # Nix state: nix.conf, tool wrappers,
      # and the dev-env symlink. Persisted on host so it survives
      # container recreation after nixos-rebuild.
      "/var/lib/hermes-agent/nix-state:/opt/data/nix-state"
    ];

    environment = {
      HERMES_HOME = "/opt/data";
      HOME = "/opt/data";
      TERMINAL_ENV = "local";
      # Restrict interaction to members of a specific Discord role.
      # GATEWAY_ALLOW_ALL_USERS MUST be false, or it overrides the allowlist
      # and lets everyone in. DISCORD_ALLOWED_ROLES auto-enables the Server
      # Members Intent (must also be toggled on in the Discord Developer Portal).
      GATEWAY_ALLOW_ALL_USERS = "false";
      DISCORD_ALLOWED_ROLES = "1485586308901634079";
      # User-ID allowlist (OR with the role). Role-based auth needs the
      # member cache, which doesn't populate reliably under host load; the
      # user-ID check is deterministic and needs no cache. Add operator IDs
      # here so they're never locked out by a stale/empty member cache.
      DISCORD_ALLOWED_USERS = "1155069673512120341";
      # PostgreSQL: use IPv6 loopback. The container has --network=host so ::1
      # works, and the amc-backend pg_hba trusts ::1/128 (but not 127.0.0.1/32).
      # The /run/postgresql Unix socket is shadowed by Podman's tmpfs on /run,
      # so it is unreachable from inside the container.
      PGHOST = "::1";
      PGPORT = "5432";
      PGUSER = "amc";
      PGDATABASE = "amc";
      # Nix environment — /nix/store is read-only, writes go through the
      # host nix-daemon socket.
      NIX_REMOTE = "unix:///nix/var/nix/daemon-socket/socket";
      NIX_STORE_DIR = "/nix/store";
      NIX_STATE_DIR = "/opt/data/nix-state/var/nix";
      NIX_LOG_DIR = "/opt/data/nix-state/var/log/nix";
      NIX_CONF_DIR = "/opt/data/nix-state/etc/nix";
      PATH = "/opt/hermes/.venv/bin:/opt/data/nix-state/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    };

    environmentFiles = [config.age.secrets.hermes-env.path];

    cmd = ["hermes" "gateway" "run"];

    extraOptions = [
      "--memory=4g"
      "--cpus=2"
      "--network=host"
      "--workdir=/opt/data"
      "--add-host=host.docker.internal:127.0.0.1"
    ];
  };

  # ── Prevent deploys from restarting the container ───────────────────
  # The hermes container holds active sessions and worktrees. Restarting it
  # on every deploy kills sessions and loses uncommitted work.
  systemd.services.podman-hermes-agent.restartIfChanged = false;

  # ── Pre-start: ensure image, seed secrets + SSH + clone/update amc-server repo ──
  systemd.services.podman-hermes-agent.serviceConfig.ExecStartPre = [
    (pkgs.writeShellScript "hermes-ensure-image" ''
      set -euo pipefail
      IMAGE_TAG="hermes-agent:local"
      REV="${hermesRev}"
      REV_FILE="/var/lib/hermes-agent/.hermes-rev"
      DOCKERFILE_VERSION="3"
      BUILD_KEY="$REV:$DOCKERFILE_VERSION"

      # Check if we have an image built for the current build key
      if [ -f "$REV_FILE" ] && [ "$(cat "$REV_FILE")" = "$BUILD_KEY" ]; then
        if ${pkgs.podman}/bin/podman images "$IMAGE_TAG" --format '{{.Repository}}:{{.Tag}}' | grep -q "$IMAGE_TAG"; then
          echo "[hermes-ensure-image] Image $IMAGE_TAG up-to-date for $BUILD_KEY."
          exit 0
        fi
      fi

      echo "[hermes-ensure-image] Image missing or stale (need $BUILD_KEY) — starting hermes-image-build.service..."
      /run/current-system/sw/bin/systemctl start hermes-image-build.service
      if ! ${pkgs.podman}/bin/podman images "$IMAGE_TAG" --format '{{.Repository}}:{{.Tag}}' | grep -q "$IMAGE_TAG"; then
        echo "[hermes-ensure-image] ERROR: Build finished but image still not found." >&2
        exit 1
      fi
      echo "[hermes-ensure-image] Image ready."
    '')
    (pkgs.writeShellScript "hermes-git-setup" ''
            set -euo pipefail

            CONTAINER_UID=10000
            CONTAINER_GID=10000

            # ── SSH directory ────────────────────────────────────────────────────────
            SSH_DIR="/var/lib/hermes-agent/.ssh"
            mkdir -p "$SSH_DIR"
            chmod 700 "$SSH_DIR"

            # Copy deploy SSH private key with permissions the container user can use.
            install -m 600 -o "$CONTAINER_UID" -g "$CONTAINER_GID" \
              "${config.age.secrets.hermes-deploy-key.path}" \
              "$SSH_DIR/id_ed25519"

            # Seed known_hosts (only needs refresh if missing)
            if [ ! -s "$SSH_DIR/known_hosts" ]; then
              ${pkgs.openssh}/bin/ssh-keyscan -H github.com > "$SSH_DIR/known_hosts" 2>/dev/null
              ${pkgs.openssh}/bin/ssh-keyscan -H asean-mt-server >> "$SSH_DIR/known_hosts" 2>/dev/null
              chown "$CONTAINER_UID:$CONTAINER_GID" "$SSH_DIR/known_hosts"
            fi

            # SSH config
            cat > "$SSH_DIR/config" << 'EOF'
      Host github.com
        HostName github.com
        User git
        IdentityFile /opt/data/.ssh/id_ed25519
        StrictHostKeyChecking yes
        UserKnownHostsFile /opt/data/.ssh/known_hosts

      Host host.docker.internal
        HostName host.docker.internal
        User root
        IdentityFile /opt/data/.ssh/id_ed25519
        StrictHostKeyChecking accept-new
        UserKnownHostsFile /opt/data/.ssh/known_hosts

      Host asean-mt-server
        User root
        ProxyCommand /opt/data/nix-state/bin/tailscale nc %h %p
        StrictHostKeyChecking yes
        UserKnownHostsFile /opt/data/.ssh/known_hosts
      EOF
            chmod 600 "$SSH_DIR/config"
            chown -R "$CONTAINER_UID:$CONTAINER_GID" "$SSH_DIR"

            # ── gitconfig ────────────────────────────────────────────────────────────
            GITCONFIG="/var/lib/hermes-agent/.gitconfig"
            cat > "$GITCONFIG" << 'EOF'
      [safe]
        directory = /opt/data/workspace/amc-server
      [user]
        name = Hermes Agent
        email = hermes@aseanmotorclub.com
      EOF
            chown "$CONTAINER_UID:$CONTAINER_GID" "$GITCONFIG"
            chmod 644 "$GITCONFIG"

            # Root-owned copy for host-side ExecStartPre git operations
            cp "$GITCONFIG" "/var/lib/hermes-agent/.gitconfig_root"
            chmod 644 "/var/lib/hermes-agent/.gitconfig_root"
            chown root:root "/var/lib/hermes-agent/.gitconfig_root"

            # ── Clone / update amc-server monorepo ───────────────────────────────────
            AMC_DIR="/var/lib/hermes-agent/workspace/amc-server"
            mkdir -p "$AMC_DIR"
            if [ ! -d "$AMC_DIR/.git" ]; then
              echo "hermes-git-setup: cloning amc-server..."
              GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -i $SSH_DIR/id_ed25519 -o UserKnownHostsFile=$SSH_DIR/known_hosts -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes" \
              HOME="/var/lib/hermes-agent" \
                ${pkgs.git}/bin/git clone git@github.com:ASEAN-Motor-Club/amc-server.git "$AMC_DIR" || \
                echo "hermes-git-setup: WARNING: amc-server clone failed — container will start without it"
            else
              echo "hermes-git-setup: fetching amc-server updates..."
              GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -i $SSH_DIR/id_ed25519 -o UserKnownHostsFile=$SSH_DIR/known_hosts -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes" \
              HOME="/var/lib/hermes-agent" \
                ${pkgs.git}/bin/git -C "$AMC_DIR" fetch --quiet || true
            fi
            # Initialise submodules (needed by the deploy script's --override-input paths)
            if [ -d "$AMC_DIR/.git" ]; then
              if [ ! -f "$AMC_DIR/amc-backend/flake.nix" ]; then
                echo "hermes-git-setup: initialising submodules..."
                GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -i $SSH_DIR/id_ed25519 -o UserKnownHostsFile=$SSH_DIR/known_hosts -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes" \
                HOME="/var/lib/hermes-agent" \
                  ${pkgs.git}/bin/git -C "$AMC_DIR" submodule update --init --recursive || \
                  echo "hermes-git-setup: WARNING: submodule init failed"
              fi
            fi
            chown -R "$CONTAINER_UID:$CONTAINER_GID" "$AMC_DIR"

            # ── Seed config files on first boot ──────────────────────────────────────
            HERMES_DIR="${./hermes}"
            if [ -d "$HERMES_DIR" ]; then
              for file in config.yaml SOUL.md AGENTS.md; do
                src="$HERMES_DIR/$file"
                dst="/var/lib/hermes-agent/$file"
                if [ -f "$src" ] && [ ! -f "$dst" ]; then
                  echo "hermes-git-setup: seeding $file"
                  install -m 644 -o "$CONTAINER_UID" -g "$CONTAINER_GID" "$src" "$dst"
                fi
              done

              # Skills directory
              if [ -d "$HERMES_DIR/skills" ]; then
                mkdir -p "/var/lib/hermes-agent/skills"
                for skill in "$HERMES_DIR"/skills/*.md; do
                  [ -e "$skill" ] || continue
                  basename=$(basename "$skill")
                  dst="/var/lib/hermes-agent/skills/$basename"
                  if [ ! -f "$dst" ]; then
                    echo "hermes-git-setup: seeding skill $basename"
                    install -m 644 -o "$CONTAINER_UID" -g "$CONTAINER_GID" "$skill" "$dst"
                  fi
                done
              fi
            fi

            # ── Nix state directories ────────────────────────────────────────────
            NIX_STATE_BASE="/var/lib/hermes-agent/nix-state"
            mkdir -p "$NIX_STATE_BASE/var/nix" \
                     "$NIX_STATE_BASE/var/log/nix" \
                     "$NIX_STATE_BASE/etc/nix" \
                     "$NIX_STATE_BASE/bin"
            chown -R "$CONTAINER_UID:$CONTAINER_GID" "$NIX_STATE_BASE"

            cat > "$NIX_STATE_BASE/etc/nix/nix.conf" << 'NIXEOF'
      experimental-features = nix-command flakes
      warn-dirty = false
      sandbox = false
      NIXEOF
            chown "$CONTAINER_UID:$CONTAINER_GID" "$NIX_STATE_BASE/etc/nix/nix.conf"

            # Create stable symlinks to the nix binaries inside the store.
            NIX_BIN=$(readlink -f /run/current-system/sw/bin/nix 2>/dev/null || true)
            if [ -z "$NIX_BIN" ] || [ ! -x "$NIX_BIN" ]; then
              NIX_BIN=$(find /nix/store -maxdepth 2 -path '*/nix-*/bin/nix' -type f 2>/dev/null | sort -V | tail -1)
            fi
            if [ -n "$NIX_BIN" ] && [ -x "$NIX_BIN" ]; then
              NIX_BIN_DIR=$(dirname "$NIX_BIN")
              ln -sf "$NIX_BIN" "$NIX_STATE_BASE/bin/nix"
              for legacy in "$NIX_BIN_DIR"/nix-*; do
                [ -e "$legacy" ] || continue
                ln -sf "$legacy" "$NIX_STATE_BASE/bin/$(basename "$legacy")"
              done
              echo "hermes-git-setup: nix + legacy commands linked into $NIX_STATE_BASE/bin (nix → $NIX_BIN)"
            else
              echo "hermes-git-setup: WARNING: nix binary not found in /nix/store"
            fi
            chown -h "$CONTAINER_UID:$CONTAINER_GID" "$NIX_STATE_BASE"/bin/nix* 2>/dev/null || true

            # Tailscale CLI — needed for Tailscale SSH ProxyCommand to asean-mt-server.
            ln -sf ${pkgs.tailscale}/bin/tailscale "$NIX_STATE_BASE/bin/tailscale"
            chown -h "$CONTAINER_UID:$CONTAINER_GID" "$NIX_STATE_BASE/bin/tailscale"

            echo "hermes-git-setup: done"
    '')
    # ── GitHub App (asean-coding-agent[bot]) setup ───────────────────────
    # Runs after hermes-git-setup: exposes gh + the credential helper, mounts
    # the App key, and configures git to use HTTPS + the App token so Hermes
    # can push and use `gh` for PRs / Actions.
    (pkgs.writeShellScript "hermes-github-app-setup" ''
      set -euo pipefail
      CONTAINER_UID=10000
      CONTAINER_GID=10000
      NIX_STATE_BASE="/var/lib/hermes-agent/nix-state"

      # App private key → volume (container: /opt/data/.github-app-key)
      install -m 600 -o "$CONTAINER_UID" -g "$CONTAINER_GID" \
        "${config.age.secrets.hermes-github-app-key.path}" \
        "/var/lib/hermes-agent/.github-app-key"

      # Expose gh + credential helper + gh-token on the container PATH
      mkdir -p "$NIX_STATE_BASE/bin"
      ln -sf ${pkgs.gh}/bin/gh "$NIX_STATE_BASE/bin/gh"
      ln -sf ${git-credential-github-app}/bin/git-credential-github-app "$NIX_STATE_BASE/bin/git-credential-github-app"
      ln -sf ${gh-token}/bin/gh-token "$NIX_STATE_BASE/bin/gh-token"
      chown -h "$CONTAINER_UID:$CONTAINER_GID" "$NIX_STATE_BASE/bin/gh" "$NIX_STATE_BASE/bin/git-credential-github-app" "$NIX_STATE_BASE/bin/gh-token"

      # Configure git: HTTPS + App credential helper, bot commit identity.
      # url.*.insteadOf rewrites the existing SSH remote to HTTPS, so the App
      # token (not the deploy key) is used for all fetch/push going forward.
      GITCONFIG="/var/lib/hermes-agent/.gitconfig"
      ${pkgs.git}/bin/git config -f "$GITCONFIG" user.name "AMC Coding Agent[bot]"
      ${pkgs.git}/bin/git config -f "$GITCONFIG" user.email "2922326+amc-coding-agent[bot]@users.noreply.github.com"
      ${pkgs.git}/bin/git config -f "$GITCONFIG" credential.helper "/opt/data/nix-state/bin/git-credential-github-app"
      ${pkgs.git}/bin/git config -f "$GITCONFIG" "url.https://github.com/.insteadOf" "git@github.com:"
      chown "$CONTAINER_UID:$CONTAINER_GID" "$GITCONFIG"
      chmod 644 "$GITCONFIG"
      cp "$GITCONFIG" "/var/lib/hermes-agent/.gitconfig_root"
      chmod 644 "/var/lib/hermes-agent/.gitconfig_root"
      chown root:root "/var/lib/hermes-agent/.gitconfig_root"

      echo "hermes-github-app-setup: done"
    '')
  ];

  # ── Post-start: merge Ragenix env vars into volume .env ──────────────
  systemd.services.podman-hermes-agent.serviceConfig.ExecStartPost = [
    # Install faster-whisper for STT (voice transcription) if not present
    (pkgs.writeShellScript "hermes-ensure-whisper" ''
      set -euo pipefail
      sleep 15
      if ${pkgs.podman}/bin/podman exec hermes-agent /opt/hermes/.venv/bin/python -c "import faster_whisper" 2>/dev/null; then
        echo "[hermes-ensure-whisper] faster-whisper already installed"
        exit 0
      fi
      echo "[hermes-ensure-whisper] Installing faster-whisper..."
      ${pkgs.podman}/bin/podman exec hermes-agent /usr/local/bin/uv pip install --python /opt/hermes/.venv/bin/python faster-whisper 2>&1 | tail -3
      echo "[hermes-ensure-whisper] faster-whisper installed"
    '')

    (pkgs.writeShellScript "hermes-env-sync" ''
      set -euo pipefail
      ENV_FILE="/var/lib/hermes-agent/.env"
      SECRET_FILE="${config.age.secrets.hermes-env.path}"

      # Wait for the volume .env to be seeded by the entrypoint
      for i in $(seq 1 10); do
        [ -f "$ENV_FILE" ] && break
        sleep 1
      done

      if [ ! -f "$ENV_FILE" ]; then
        echo "hermes-env-sync: .env not found after 10s, skipping"
        exit 0
      fi

      # Append each line from the secret file to the volume .env,
      # replacing existing entries if present
      while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue
        KEY="''${line%%=*}"
        sed -i "/^$KEY=/d" "$ENV_FILE"
        echo "$line" >> "$ENV_FILE"
      done < "$SECRET_FILE"

      echo "hermes-env-sync: .env updated from secret"
    '')
  ];
}
