#!/usr/bin/env bash
set -euo pipefail

NIXOS_REPO="/home/claw/nixos"
PROJECTS_DIR="/home/claw/projects"
DEVENVS_DIR="/home/claw/devenvs"
OPENCODE_PORT=4096

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

# Generate the flake for a container
generate_flake() {
  local name="$1"
  local project_dir="$2"
  local flake_dir="$DEVENVS_DIR/$name"
  local system_arch="${3:-$(uname -m)}"

  case "$system_arch" in
    x86_64) system_arch="x86_64-linux" ;;
    aarch64) system_arch="aarch64-linux" ;;
    arm64) system_arch="aarch64-linux" ;;
    *) echo "error: unsupported architecture: $system_arch" >&2; exit 1 ;;
  esac

  mkdir -p "$flake_dir"

  # Copy container module so flake can import it with a relative path (no --impure needed)
  cp "$NIXOS_REPO/devenvs/container.nix" "$flake_dir/container.nix"

  sed \
    -e "s/@NAME@/$name/g" \
    -e "s/@SYSTEM@/$system_arch/g" \
    "$NIXOS_REPO/devenvs/flake.template.nix" > "$flake_dir/flake.nix"

  # Copy host flake.lock so we reuse already-cached store paths
  if [[ -f "$NIXOS_REPO/flake.lock" ]]; then
    cp "$NIXOS_REPO/flake.lock" "$flake_dir/flake.lock"
  fi
}

# Configure bind mounts in the nixos-containers conf file.
# Must be called AFTER nixos-container create has written the conf file.
# Note: nixos-container uses --keep-unit which causes systemd-nspawn to ignore
# .nspawn drop-in files, so all extra flags must go through EXTRA_NSPAWN_FLAGS.
configure_container() {
  local name="$1"
  local project_dir="$2"
  local conf="/etc/nixos-containers/$name.conf"

  # Create mount point for secret file — nspawn requires the target to exist for file bind mounts
  sudo mkdir -p /var/lib/nixos-containers/"$name"/etc/secrets
  sudo touch /var/lib/nixos-containers/"$name"/etc/secrets/ts_auth_key

  sudo tee -a "$conf" > /dev/null <<CONF
EXTRA_NSPAWN_FLAGS=--bind=$project_dir:/project --bind=/home/claw/.cache/opencode:/home/dev/.cache/opencode --bind-ro=/run/secrets/tailscale_devenv_auth_key:/etc/secrets/ts_auth_key
CONF
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
    # systemd truncates unit names beyond this length
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

  echo "Generating container flake..."
  generate_flake "$name" "$project_dir" "$system_arch"

  cleanup_on_failure() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
      echo "Failed, cleaning up..."
      rm -rf "$flake_dir"
      rm -rf "$project_dir"
    fi
  }
  trap cleanup_on_failure EXIT

  echo "Building and creating container '$name'..."
  sudo nixos-container create "$name" \
    --flake "$flake_dir"

  echo "Configuring bind mounts..."
  configure_container "$name" "$project_dir"

  echo "Starting container..."
  sudo nixos-container start "$name"

  trap - EXIT

  echo ""
  echo "Done! Dev environment '$name' is running."
  echo "OpenCode: http://$name:$OPENCODE_PORT"
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

  rm -rf "$DEVENVS_DIR/$name"

  echo "Container destroyed. Project directory preserved at: $PROJECTS_DIR/$name"
}

cmd_list() {
  local containers
  containers=$(sudo nixos-container list 2>/dev/null || true)

  if [[ -z "$containers" ]]; then
    echo "No dev environments."
    return
  fi

  printf "%-12s %-8s %s\n" "NAME" "STATUS" "URL"
  printf "%-12s %-8s %s\n" "----" "------" "---"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    # Only show containers managed by devenv (have a flake dir)
    [[ ! -d "$DEVENVS_DIR/$name" ]] && continue
    local status
    status=$(sudo nixos-container status "$name" 2>/dev/null || echo "gone")
    printf "%-12s %-8s %s\n" "$name" "$status" "http://$name:$OPENCODE_PORT"
  done <<< "$containers"
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
