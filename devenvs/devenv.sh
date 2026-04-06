#!/usr/bin/env bash
set -euo pipefail

NIXOS_REPO="/home/claw/nixos"
PROJECTS_DIR="/home/claw/projects"
DEVENVS_DIR="/home/claw/devenvs"
PORTS_FILE="/home/claw/.devenvs/ports.json"
LOCK_FILE="$PORTS_FILE.lock"
PORT_START=4101
PORT_END=4199

usage() {
  cat <<EOF
Usage: devenv <command> [args]

Commands:
  create <name> [--repo <url>]   Create and start a new dev environment
  start <name>                   Start a stopped environment
  stop <name>                    Stop a running environment
  destroy <name>                 Destroy container (project dir kept)
  list                           List environments and their status
  shell <name>                   Open a root shell in the container

Options for create:
  --repo <url>   Clone this git repo (default: git init)
EOF
}

# Ensure ports registry exists
ensure_ports_file() {
  if [[ ! -f "$PORTS_FILE" ]]; then
    mkdir -p "$(dirname "$PORTS_FILE")"
    echo '{"next_port":'"$PORT_START"',"allocations":{}}' > "$PORTS_FILE"
  fi
}

# Allocate a port for a container name, return the port
allocate_port() {
  local name="$1"
  ensure_ports_file

  exec 200>"$LOCK_FILE"
  flock 200

  local existing
  existing=$(jq -r ".allocations[\"$name\"] // empty" "$PORTS_FILE")
  if [[ -n "$existing" ]]; then
    flock -u 200
    echo "$existing"
    return
  fi
  local port
  port=$(jq -r '.next_port' "$PORTS_FILE")
  if [[ "$port" -gt "$PORT_END" ]]; then
    flock -u 200
    echo "error: port range $PORT_START-$PORT_END exhausted" >&2
    exit 1
  fi
  jq ".next_port = ($port + 1) | .allocations[\"$name\"] = $port" "$PORTS_FILE" > "${PORTS_FILE}.tmp"
  mv "${PORTS_FILE}.tmp" "$PORTS_FILE"
  flock -u 200
  echo "$port"
}

# Free a port allocation
free_port() {
  local name="$1"
  ensure_ports_file

  exec 200>"$LOCK_FILE"
  flock 200

  jq "del(.allocations[\"$name\"])" "$PORTS_FILE" > "${PORTS_FILE}.tmp"
  mv "${PORTS_FILE}.tmp" "$PORTS_FILE"

  flock -u 200
}

# Generate the flake for a container
generate_flake() {
  local name="$1"
  local port="$2"
  local project_dir="$3"
  local flake_dir="$DEVENVS_DIR/$name"
  local system_arch="${4:-$(uname -m)}"

  case "$system_arch" in
    x86_64) system_arch="x86_64-linux" ;;
    aarch64) system_arch="aarch64-linux" ;;
    arm64) system_arch="aarch64-linux" ;;
  esac

  mkdir -p "$flake_dir"

  # Copy container module so flake can import it with a relative path (no --impure needed)
  cp "$NIXOS_REPO/devenvs/container.nix" "$flake_dir/container.nix"

  cat > "$flake_dir/flake.nix" <<FLAKE
{
  description = "Dev environment: $name";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    opencode.url = "github:sst/opencode";
    vscode-server.url = "github:nix-community/nixos-vscode-server";
    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      opencode,
      vscode-server,
      home-manager,
      ...
    }:
    {
      nixosConfigurations."container" = nixpkgs.lib.nixosSystem {
        system = "$system_arch";
        specialArgs = {
          inherit opencode;
          opencodePort = $port;
          projectName = "$name";
        };
        modules = [
          vscode-server.nixosModules.default
          home-manager.nixosModules.home-manager
          { home-manager.useGlobalPkgs = true; }
          ./container.nix
          {
            home-manager.users.dev.imports = [ vscode-server.homeModules.default ];
          }
        ];
      };
    };
}
FLAKE

  # Copy host flake.lock so we reuse already-cached store paths
  if [[ -f "$NIXOS_REPO/flake.lock" ]]; then
    cp "$NIXOS_REPO/flake.lock" "$flake_dir/flake.lock"
  fi
}

# Write the nspawn override file for bind-mounting the project dir
write_nspawn_file() {
  local name="$1"
  local project_dir="$2"
  local port="$3"
  sudo mkdir -p /etc/systemd/nspawn
  sudo tee /etc/systemd/nspawn/"$name".nspawn > /dev/null <<NSPAWN
[Files]
Bind=$project_dir:/project
Bind=/home/claw/.cache/opencode:/home/dev/.cache/opencode

[Network]
Port=tcp:$port:$port
NSPAWN
}

# Remove nspawn override file
remove_nspawn_file() {
  local name="$1"
  sudo rm -f /etc/systemd/nspawn/"$name".nspawn
}

cmd_create() {
  local name=""
  local repo_url=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo_url="$2"; shift 2 ;;
      -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
      *) name="$1"; shift ;;
    esac
  done

  [[ -z "$name" ]] && { echo "error: container name required" >&2; usage; exit 1; }

  if [[ ${#name} -gt 11 ]]; then
    echo "error: container name must be ≤11 characters (got ${#name}: '$name')" >&2
    exit 1
  fi

  local project_dir="$PROJECTS_DIR/$name"
  local flake_dir="$DEVENVS_DIR/$name"
  local system_arch
  system_arch=$(uname -m)

  if [[ -e "$project_dir" ]]; then
    echo "error: project directory '$project_dir' already exists" >&2
    exit 1
  fi

  if [[ -d "$flake_dir" ]]; then
    echo "error: devenv '$name' already exists" >&2
    exit 1
  fi

  # Set up project directory
  mkdir -p "$PROJECTS_DIR"
  if [[ -n "$repo_url" ]]; then
    echo "Cloning $repo_url into $project_dir..."
    git clone "$repo_url" "$project_dir"
  else
    echo "Initializing new repo at $project_dir..."
    mkdir -p "$project_dir"
    git -C "$project_dir" init
  fi

  local port
  port=$(allocate_port "$name")

  echo "Generating container flake (port $port)..."
  generate_flake "$name" "$port" "$project_dir" "$system_arch"

  echo "Writing bind mount config..."
  write_nspawn_file "$name" "$project_dir" "$port"

  cleanup_on_failure() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
      echo "Failed, cleaning up..."
      remove_nspawn_file "$name"
      free_port "$name"
      rm -rf "$flake_dir"
    fi
  }
  trap cleanup_on_failure EXIT

  echo "Building and creating container '$name'..."
  sudo nixos-container create "$name" \
    --flake "$flake_dir"

  echo "Starting container..."
  sudo nixos-container start "$name"

  trap - EXIT

  echo ""
  echo "Done! Dev environment '$name' is running."
  echo "OpenCode: http://ociclaw-1:$port"
  echo "Shell:    devenv shell $name"
}

cmd_start() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "error: container name required" >&2; exit 1; }
  sudo nixos-container start "$name"
}

cmd_stop() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "error: container name required" >&2; exit 1; }
  sudo nixos-container stop "$name"
}

cmd_destroy() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "error: container name required" >&2; exit 1; }

  echo "Destroying container '$name'..."
  sudo nixos-container destroy "$name" 2>/dev/null || true

  remove_nspawn_file "$name"
  rm -rf "$DEVENVS_DIR/$name"
  free_port "$name"

  echo "Container destroyed. Project directory preserved at: $PROJECTS_DIR/$name"
}

cmd_list() {
  ensure_ports_file
  local allocations
  allocations=$(jq -r '.allocations | to_entries[] | "\(.key) \(.value)"' "$PORTS_FILE" 2>/dev/null || true)

  if [[ -z "$allocations" ]]; then
    echo "No dev environments."
    return
  fi

  printf "%-12s %-6s %-8s %s\n" "NAME" "PORT" "STATUS" "URL"
  printf "%-12s %-6s %-8s %s\n" "----" "----" "------" "---"

  while IFS=' ' read -r name port; do
    local status
    status=$(sudo nixos-container status "$name" 2>/dev/null || echo "gone")
    printf "%-12s %-6s %-8s %s\n" "$name" "$port" "$status" "http://ociclaw-1:$port"
  done <<< "$allocations"
}

cmd_shell() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "error: container name required" >&2; exit 1; }
  sudo nixos-container root-login "$name"
}

# Main dispatch
[[ $# -eq 0 ]] && { usage; exit 1; }

case "$1" in
  create)  shift; cmd_create "$@" ;;
  start)   shift; cmd_start "$@" ;;
  stop)    shift; cmd_stop "$@" ;;
  destroy) shift; cmd_destroy "$@" ;;
  list)    cmd_list ;;
  shell)   shift; cmd_shell "$@" ;;
  -h|--help|help) usage ;;
  *) echo "Unknown command: $1" >&2; usage; exit 1 ;;
esac
