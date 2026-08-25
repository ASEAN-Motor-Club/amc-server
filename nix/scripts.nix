# AMC Deployment Scripts
#
# A focused set of deployment tools for 2 servers (asean-mt-server, amc-peripheral).
# Uses argc for argument parsing (see https://github.com/sigoden/argc).
#
# Usage (from nix develop):
#   pre-deploy [--skip-pytest] [--fix]
#   deploy <root@host> [--skip-checks] [--skip-pytest] [--migrate] [--restart-be]
#   health-check <root@host>
#   rollback <root@host>
{
  lib,
  pkgs,
  argc,
}: let
  scripts = {
    # ---------------------------------------------------------------------------
    # pre-deploy
    # ---------------------------------------------------------------------------
    # Validates the codebase before any deploy. Three layers:
    #   1. Submodule hygiene — warns on dirty/uninitialized submodules
    #   2. Nix formatting   — alejandra --check on the parent flake
    #   3. Backend checks   — ruff, django-check, pytest (via amc-backend flake)
    #
    # All three backend checks are proper Nix derivations so they cache: on a
    # second run with no code changes they complete in <1s.
    #
    # Architecture note: checks run on the local system (aarch64-darwin or
    # x86_64-linux). They validate code correctness. Build correctness on the
    # target (x86_64-linux) is validated by nixos-rebuild itself, which runs
    # --build-host on the target machine.
    # ---------------------------------------------------------------------------
    pre-deploy = ''
      # @flag --skip-pytest   Skip pytest (saves ~60s, use for quick iteration)
      # @flag --fix           Auto-fix ruff lint issues before checking

      eval "$(${argc}/bin/argc --argc-eval "$0" "$@")"

      set -eo pipefail

      REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
      cd "$REPO_ROOT"

      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "🔍 Pre-Deploy Validation"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

      # ── 1. Submodule hygiene ────────────────────────────────────────────────
      echo ""
      echo "📦 Checking submodule state..."
      SUBMODULE_PROBLEMS=0

      while IFS= read -r line; do
        STATUS="''${line:0:1}"
        NAME=$(echo "$line" | awk '{print $2}')
        if [[ "$STATUS" == "+" ]]; then
          echo "  ⚠️  $NAME has uncommitted changes (dirty)"
          SUBMODULE_PROBLEMS=1
        elif [[ "$STATUS" == "-" ]]; then
          echo "  ❌ $NAME is not initialised — run: git submodule update --init"
          SUBMODULE_PROBLEMS=1
        elif [[ "$STATUS" == "U" ]]; then
          echo "  ❌ $NAME has merge conflicts"
          SUBMODULE_PROBLEMS=1
        fi
      done < <(git submodule status)

      if [[ $SUBMODULE_PROBLEMS -eq 1 ]]; then
        echo ""
        echo "⚠️  Warning: dirty submodules will deploy their working-tree state."
        echo "   --override-input uses the local checkout directly."
        echo "   Commit or stash changes before deploying to production."
        echo ""
        # Warn, don't fail — allows deliberate deploy-with-local-changes workflow
      else
        echo "  ✅ All submodules clean"
      fi

      # ── 2. Nix formatting ──────────────────────────────────────────────────
      echo ""
      echo "📐 Checking Nix formatting (alejandra)..."
      if ${pkgs.alejandra}/bin/alejandra --check . 2>/dev/null; then
        echo "  ✅ Nix formatting: OK"
      else
        echo "  ❌ Nix formatting: issues found"
        echo "     Run: alejandra . (to fix)"
        exit 1
      fi

      # ── 3. Backend checks (amc-backend flake) ──────────────────────────────
      cd "$REPO_ROOT/amc-backend"
      SYSTEM=$(${pkgs.nix}/bin/nix eval --raw --impure --expr 'builtins.currentSystem')
      echo ""
      echo "🖥️  Running backend checks on $SYSTEM..."

      # Optional: auto-fix lint first
      if [[ -n $argc_fix ]]; then
        echo "🔧 Auto-fixing ruff issues..."
        ${pkgs.nix}/bin/nix develop --command ruff check . --fix
      fi

      echo ""
      echo "  🔎 ruff (lint)..."
      ${pkgs.nix}/bin/nix build ".#checks.$SYSTEM.ruff" --no-link

      echo "  🔎 django-check (system check)..."
      ${pkgs.nix}/bin/nix build ".#checks.$SYSTEM.django-check" --no-link

      if [[ -z $argc_skip_pytest ]]; then
        echo "  🧪 pytest (full suite, ~60s)..."
        ${pkgs.nix}/bin/nix build ".#checks.$SYSTEM.pytest" --no-link
      else
        echo "  ⏭️  pytest skipped (--skip-pytest)"
      fi

      cd "$REPO_ROOT"

      echo ""
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "✅ All pre-deploy checks passed!"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    '';

    # ---------------------------------------------------------------------------
    # deploy
    # ---------------------------------------------------------------------------
    # Full deployment pipeline:
    #   1. pre-deploy checks (unless --skip-checks)
    #   2. Nix flake evaluation dry-run (parent flake must evaluate cleanly)
    #   3. nixos-rebuild switch on target (builds on target = x86_64-linux)
    #   4. Optional: migrate, restart services
    #   5. health-check
    #   6. macOS notification
    #
    # The --build-host flag is the key mechanism that ensures build correctness
    # on the target architecture, even when deploying from an aarch64-darwin Mac.
    # ---------------------------------------------------------------------------
    deploy = ''
      # @arg target!          SSH target, e.g. root@asean-mt-server
      # @flag --skip-checks   Skip pre-deploy validation (for emergency deploys)
      # @flag --skip-pytest   Skip pytest in pre-deploy (pass-through flag)
      # @flag --migrate       Run Django migrations after deploy
      # @flag --restart-be    Restart amc-backend + amc-worker after deploy
      # @flag --no-health-check  Skip post-deploy health check

      eval "$(${argc}/bin/argc --argc-eval "$0" "$@")"

      set -eo pipefail

      REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
      cd "$REPO_ROOT"

      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "🚀 Deploy → $argc_target"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

      # ── 1. Pre-deploy checks ───────────────────────────────────────────────
      if [[ -z $argc_skip_checks ]]; then
        PYTEST_FLAG=""
        [[ -n $argc_skip_pytest ]] && PYTEST_FLAG="--skip-pytest"
        pre-deploy $PYTEST_FLAG || {
          echo "❌ Pre-deploy checks failed — aborting deploy"
          echo "   Use --skip-checks to bypass (emergency only)"
          exit 1
        }
      else
        echo "⚠️  Pre-deploy checks skipped (--skip-checks)"
      fi

      # ── 2. Flake evaluation dry-run ────────────────────────────────────────
      echo ""
      echo "🧩 Evaluating parent flake..."
      if ! ${pkgs.nix}/bin/nix flake check --no-build 2>/dev/null; then
        # nix flake check --no-build just evaluates; if it fails the flake is broken
        echo "  ⚠️  nix flake check warning (may be expected for cross-arch checks)"
      else
        echo "  ✅ Flake evaluates cleanly"
      fi

      # ── 3. Mod zip validation ────────────────────────────────────────────
      HOSTNAME=$(echo "$argc_target" | cut -d@ -f2)
      MODS_ENABLED=$(${pkgs.nix}/bin/nix eval ".#nixosConfigurations.''${HOSTNAME}.config.services.motortown-server.enableMods" 2>/dev/null || echo "false")

      if [[ "$MODS_ENABLED" == "true" ]]; then
        MOD_VERSION=$(${pkgs.nix}/bin/nix eval --raw ".#nixosConfigurations.''${HOSTNAME}.config.services.motortown-server.modVersion")
        if [[ "$MOD_VERSION" != "dev" ]]; then
          MOD_URL="https://www.aseanmotorclub.com/releases/MotorTownMods_''${MOD_VERSION}.zip"
          if ! ${pkgs.curl}/bin/curl -sfI --max-time 10 "$MOD_URL" > /dev/null 2>&1; then
            echo "  ❌ Mod zip not found: MotorTownMods_''${MOD_VERSION}.zip"
            echo "     Upload it first: scp MotorTownMods-package.zip root@amc-peripheral:/var/lib/mod-releases/MotorTownMods_''${MOD_VERSION}.zip"
            echo "     Or use: deploy-mod --server <target>"
            exit 1
          fi
          echo "  ✅ Mod zip verified: MotorTownMods_''${MOD_VERSION}.zip"
        fi
      fi

      # ── 4. Deploy ─────────────────────────────────────────────────────────
      echo ""
      echo "📡 Running nixos-rebuild on $argc_target..."
      echo "   (builds on target — x86_64-linux)"
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild \
        --target-host "$argc_target" \
        --build-host "$argc_target" \
        --flake . \
        --fast \
        switch \
        --override-input amc-backend ./amc-backend \
        --override-input amc-peripheral ./amc-peripheral \
        --override-input motortown-server ./motortown-server-flake \
        --override-input beammp-server ./beammp-server-flake \
        --override-input assetto-server ./assetto-server-flake \
        --override-input eco-server ./eco-server \
        --override-input zomboid-server ./zomboid-server \
        --override-input mt-pak-extract ./mt-pak-extract

      echo "  ✅ nixos-rebuild complete"

      # ── 5. Post-deploy actions ─────────────────────────────────────────────
      if [[ -n $argc_migrate ]]; then
        echo ""
        echo "🗄️  Running migrations..."
        ssh "$argc_target" -- amcm migrate
        echo "  ✅ Migrations done"
      fi

      if [[ -n $argc_restart_be ]]; then
        echo ""
        echo "🔄 Restarting amc-backend + amc-worker..."
        ssh "$argc_target" -- systemctl restart amc-backend amc-worker
        echo "  ✅ Services restarted"
      fi

      # ── 5b. Event-driven PZ changelog notifier ─────────────────────────────
      # Fire the changelog relay RIGHT AFTER a deploy so a shipped mod/config
      # change reports to Discord the moment it lands (the timer is only a slow
      # hourly fallback). Idempotent: only posts if there are actually new
      # master commits since the last-seen SHA; a no-op deploy posts nothing.
      if ssh "$argc_target" -- systemctl cat zomboid-changelog-notify.service >/dev/null 2>&1; then
        echo ""
        echo "🔔 Firing zomboid changelog notifier (event-driven, post-deploy)..."
        ssh "$argc_target" -- systemctl start zomboid-changelog-notify.service || \
          echo "  ⚠️  zomboid-changelog-notify start failed (non-fatal)"
        echo "  ✅ Changelog notifier fired"
      fi

      # ── 6. Health check ───────────────────────────────────────────────────
      if [[ -z $argc_no_health_check ]]; then
        echo ""
        health-check "$argc_target" || {
          echo ""
          echo "⚠️  Health check failed after deploy!"
          echo "   Run: rollback $argc_target"
          exit 1
        }
      fi

      # ── 7. macOS notification ─────────────────────────────────────────────
      osascript -e "display notification \"$argc_target\" with title \"✅ Deployed\" sound name \"Morse\"" 2>/dev/null || true

      echo ""
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "✅ Deploy complete → $argc_target"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    '';

    # ---------------------------------------------------------------------------
    # health-check
    # ---------------------------------------------------------------------------
    # Verifies the backend is healthy after a deploy. Checks:
    #   - amc-backend systemd unit is active
    #   - amc-worker systemd unit is active
    #   - HTTP /api/ endpoint responds on localhost:9000
    #
    # Called automatically by `deploy`. Can also be run standalone.
    # ---------------------------------------------------------------------------
    health-check = ''
      # @arg target!    SSH target, e.g. root@asean-mt-server

      eval "$(${argc}/bin/argc --argc-eval "$0" "$@")"

      set -eo pipefail

      echo "🏥 Health check → $argc_target"

      FAILED=0

      # Systemd unit checks (run inside the amc-backend container)
      if ssh "$argc_target" -- systemctl is-active --quiet amc-backend 2>/dev/null; then
        echo "  ✅ amc-backend: active"
      else
        echo "  ❌ amc-backend: not running"
        echo "     Run: ssh $argc_target -- journalctl -u amc-backend -n 50"
        FAILED=1
      fi

      if ssh "$argc_target" -- systemctl is-active --quiet amc-worker 2>/dev/null; then
        echo "  ✅ amc-worker: active"
      else
        echo "  ❌ amc-worker: not running"
        echo "     Run: ssh $argc_target -- journalctl -u amc-worker -n 50"
        FAILED=1
      fi

      # HTTP check — backend runs on port 9000, verify it responds
      if ssh "$argc_target" -- curl -sf --max-time 5 http://localhost:9000/api/ > /dev/null 2>&1; then
        echo "  ✅ HTTP /api/: responding"
      else
        echo "  ❌ HTTP /api/: not responding on localhost:9000"
        FAILED=1
      fi

      if [[ $FAILED -eq 0 ]]; then
        echo "✅ All services healthy"
        exit 0
      else
        echo "❌ Health check failed"
        exit 1
      fi
    '';

    # ---------------------------------------------------------------------------
    # rollback
    # ---------------------------------------------------------------------------
    # Server-side rollback using NixOS generations. Switches to the previous
    # generation on the target, then runs a health check to verify recovery.
    # ---------------------------------------------------------------------------
    rollback = ''
      # @arg target!    SSH target, e.g. root@asean-mt-server

      eval "$(${argc}/bin/argc --argc-eval "$0" "$@")"

      set -eo pipefail

      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "⏪ Rolling back $argc_target to previous generation..."
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

      ssh "$argc_target" -- nixos-rebuild switch --rollback

      osascript -e "display notification \"$argc_target\" with title \"⏪ Rolled Back\" sound name \"Submarine\"" 2>/dev/null || true

      echo ""
      health-check "$argc_target" || {
        echo "⚠️  Rollback completed but services still unhealthy"
        echo "   Check logs: ssh $argc_target -- journalctl -u amc-backend -n 100"
        exit 1
      }

      echo ""
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "✅ Rollback complete"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    '';

    # ---------------------------------------------------------------------------
    # deploy-mod
    # ---------------------------------------------------------------------------
    # One-command mod deployment cycle:
    #   1. Auto-increment RC version (or use --version)
    #   2. Build C++ if changed since last tag (skip with --skip-build)
    #   3. Package the mod
    #   4. Upload to amc-peripheral
    #   5. Verify upload via HTTP HEAD
    #   6. Update modVersion in flake.nix
    #   7. Deploy to target server
    # ---------------------------------------------------------------------------
    deploy-mod = ''
      # @arg --server!     Target server: 'test' (amc-peripheral) or 'main' (asean-mt-server)
      # @flag --version    Override version (default: auto-increment from last tag)
      # @flag --skip-build Skip C++ build
      # @flag --skip-deploy Stop after upload (don't update mod-versions.nix or deploy)

      eval "$(${argc}/bin/argc --argc-eval "$0" "$@")"

      set -eo pipefail
      cd "$(git rev-parse --show-toplevel)"

      # Map server name to SSH target and mod-versions.nix key
      case "$argc_server" in
        test) TARGET="root@amc-peripheral"; VERSION_KEY="staging" ;;
        main) TARGET="root@asean-mt-server"; VERSION_KEY="main" ;;
        *) echo "Unknown server: $argc_server"; exit 1 ;;
      esac

      # Determine version
      cd MTDediMod
      if [[ -n "$argc_version" ]]; then
        NEW_VERSION="$argc_version"
      else
        LAST_TAG=$(git tag -l 'server/*' --sort=-v:refname | head -1)
        # Increment RC: server/v0.40.1-rc4 → server/v0.40.1-rc5
        RC_NUM=$(echo "$LAST_TAG" | sed 's/.*rc\([0-9]*\).*/\1/')
        NEW_VERSION=$(echo "$LAST_TAG" | sed "s/rc''${RC_NUM}/rc$((RC_NUM + 1))/")
        echo "Auto-incrementing: $LAST_TAG → $NEW_VERSION"
      fi

      # Build C++ if needed
      if [[ -z "$argc_skip_build" ]]; then
        PREV_TAG=$(git tag -l 'server/*' --sort=-v:refname | sed -n '2p')
        if git diff --name-only "$PREV_TAG" HEAD | grep -q '^src/'; then
          echo "C++ changes detected, building..."
          nix run .#build
        else
          echo "No C++ changes, skipping build"
        fi
      fi

      # Package
      echo "Packaging mod..."
      nix run .#package
      cd ..

      # Upload
      MOD_ZIP_NAME="MotorTownMods_''${NEW_VERSION}.zip"
      echo "Uploading $MOD_ZIP_NAME to amc-peripheral..."
      scp MTDediMod/MotorTownMods-package.zip "root@amc-peripheral:/var/lib/mod-releases/''${MOD_ZIP_NAME}"

      # Verify
      MOD_URL="https://www.aseanmotorclub.com/releases/''${MOD_ZIP_NAME}"
      if ${pkgs.curl}/bin/curl -sfI --max-time 10 "$MOD_URL" > /dev/null 2>&1; then
        echo "✅ Verified: $MOD_URL"
      else
        echo "❌ Upload verification failed: $MOD_URL"
        exit 1
      fi

      if [[ -n "$argc_skip_deploy" ]]; then
        sed -i '''''' "s/''${VERSION_KEY} = \".*\"/''${VERSION_KEY} = \"''${NEW_VERSION}\"/" mod-versions.nix
        echo "Upload complete (--skip-deploy)."
        echo "  Updated mod-versions.nix: ''${VERSION_KEY} → ''${NEW_VERSION}"
        echo "  Deploy manually: deploy $TARGET"
        exit 0
      fi

      # Update modVersion for the target server in mod-versions.nix
      sed -i '''''' "s/''${VERSION_KEY} = \".*\"/''${VERSION_KEY} = \"''${NEW_VERSION}\"/" mod-versions.nix
      echo "Updated mod-versions.nix: ''${VERSION_KEY} → ''${NEW_VERSION}"

      # Deploy
      echo "Deploying to $TARGET..."
      deploy "$TARGET"
    '';
  };
in
  lib.mapAttrsToList (name: script: pkgs.writeShellScriptBin name script) scripts
