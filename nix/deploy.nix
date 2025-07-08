{ pkgs }:
let
  settings = {
    amc-radio-experimental = {
      targetHost = "root@139.180.140.8";
      port = "222";
    };
  };
in
pkgs.writeShellScriptBin "deploy" ''
  set -e

  #
  # A simple deployment script that accepts a server URI and an optional SSH port.
  #
  # Usage:
  #   ./deploy.sh [server_uri]
  #   ./deploy.sh --ssh-port=[port] [server_uri]
  #

  # --- Default Configuration ---
  # Set the default SSH port. This will be used if the --ssh-port argument is not provided.
  SSH_PORT=22
  TARGET_HOST=""

  # --- Argument Parsing ---
  # Iterate over all arguments passed to the script to identify the server URI and any options.
  for arg in "$@"
  do
      case $arg in
          # Check for the --ssh-port option.
          # It expects the format --ssh-port=VALUE
          --ssh-port=*)
          # Extract the value after the '=' character and assign it to SSH_PORT.
          SSH_PORT="''${arg#*=}"
          ;;
          # Capture any argument that doesn't start with a hyphen.
          # We assume this is the server URI.
          -*)
          echo "Error: Unknown option '$arg'"
          echo "Usage: $0 --ssh-port=[optional_ssh_port] [server_uri]"
          exit 1
          ;;
          *)
          # If the TARGET_HOST variable is already set, it means a second URI was provided.
          if [ -n "$TARGET_HOST" ]; then
              echo "Error: Please provide only one server URI."
              exit 1
          fi
          # Assign the argument to the TARGET_HOST variable.
          TARGET_HOST="$arg"
          ;;
      esac
  done

  if [ -z "$TARGET_HOST" ]; then
      echo "Error: Server URI is a required argument."
      echo "Usage: $0 --ssh-port=[optional_ssh_port] [target_host]"
      exit 1
  fi

  case "$TARGET_HOST" in
    ${builtins.concatStringsSep "\n" (
      pkgs.lib.mapAttrsToList (hostName: hostSettings: ''
        "${hostName}")
          echo "Settings found for ${hostName}"
          TARGET_HOST="${hostSettings.targetHost}"
          SSH_PORT="${hostSettings.port}"
          ;;
      '') settings
    )}
    *)
      ;;
  esac

  # --- Execution ---
  # Display the parsed configuration that will be used for deployment.
  echo "🚀  Starting deployment..."
  echo "--------------------------------"
  echo "  Server      : $TARGET_HOST"
  echo "  SSH Port    : $SSH_PORT"
  echo "--------------------------------"


  NIX_SSHOPTS="-p $SSH_PORT" ${pkgs.nixos-rebuild}/bin/nixos-rebuild --target-host "$TARGET_HOST" --build-host "$TARGET_HOST" --flake .?submodules=1# --fast switch

  exit 0
''

