#!/usr/bin/env bash
set -euo pipefail

NIXOS_REPO="/home/claw/nixos"
PROJECTS_DIR="/home/claw/projects"
DEVENVS_DIR="/home/claw/devenvs"
OPENCODE_PORT=4096

# Source centralized configuration
if [[ -f "$DEVENVS_DIR/config.sh" ]]; then
  source "$DEVENVS_DIR/config.sh" || true
fi

: "${PROJECT_MOUNT_PATH:=/}"

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
  rebuild <name>                 Rebuild container from flake (stop/update/start)
  rebuildf <name>                Force rebuild: destroy & recreate
  logs <name> [lines] [service]  Show container journal (default 50 lines)
  status <name>                  Show container health (services, mounts, tailscale)
  url <name> [--user <user>]    Generate VS Code Remote URL
  exec <name> [--user <user>] <cmd...>  Run a command inside the container

Options for create:
  --repo <url>   Clone this git repo (default: git init)
Options for url/exec:
  --user <user>  SSH user (default: dev)
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
    -e "s/@MOUNT_PATH@/$PROJECT_MOUNT_PATH/g" \
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
  sudo touch /var/lib/nixos-containers/"$name"/etc/secrets/github_pat

  sudo tee -a "$conf" > /dev/null <<CONF
EXTRA_NSPAWN_FLAGS=--bind=$project_dir:${PROJECT_MOUNT_PATH}$name --bind=/home/claw/.cache/opencode:/home/dev/.cache/opencode --bind-ro=/run/secrets/tailscale_devenv_auth_key:/etc/secrets/ts_auth_key --bind-ro=/run/secrets/github_pat:/etc/secrets/github_pat
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

# Run a command inside a container via machinectl shell.
# machinectl shell requires absolute paths, so we wrap through bash -lc.
# Usage: container_exec <name> [user@] "command string" [ignore_errors]
container_exec() {
  local name="$1"
  local target="$2"
  local cmd="$3"
  local ignore_errors="${4:-false}"
  [[ -z "$target" ]] && target="$name"
  local tmpfile
  tmpfile=$(mktemp)
  set -o pipefail
  sudo machinectl shell "$target" /run/current-system/sw/bin/bash -lc "$cmd" 2>&1 | grep -v "^Connected to\|^Connection to\|^Press \^]" > "$tmpfile"
  local rc=$?
  set +o pipefail
  cat "$tmpfile"
  rm -f "$tmpfile"
  if [[ "$ignore_errors" != "true" && $rc -ne 0 ]]; then
    return $rc
  fi
}

# Wait for a container to reach running or degraded state
wait_for_container() {
  local name="$1"
  local max_wait="${2:-30}"
  local elapsed=0
  while [[ $elapsed -lt $max_wait ]]; do
    if container_exec "$name" "" "systemctl is-system-running" "" true | grep -qE "running|degraded"; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  echo "warning: container '$name' did not become ready within ${max_wait}s" >&2
  return 1
}

cmd_rebuild() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "error: container name required" >&2; exit 1; }

  local flake_dir="$DEVENVS_DIR/$name"
  [[ ! -d "$flake_dir" ]] && { echo "error: devenv '$name' does not exist" >&2; exit 1; }

  echo "Rebuilding container '$name'..."
  sudo nixos-container stop "$name" 2>/dev/null || true
  sudo nixos-container update "$name" --flake "$flake_dir"
  sudo nixos-container start "$name"

  echo "Waiting for container to be ready..."
  wait_for_container "$name"

  echo "Done! Container '$name' rebuilt."
}

cmd_rebuildf() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "error: container name required" >&2; exit 1; }

  local flake_dir="$DEVENVS_DIR/$name"
  local project_dir="$PROJECTS_DIR/$name"

  echo "Force rebuild: destroying container '$name'..."
  sudo nixos-container destroy "$name" 2>/dev/null || true

  echo "Regenerating flake and recreating..."
  generate_flake "$name" "$project_dir" "$(uname -m)"

  sudo nixos-container create "$name" --flake "$flake_dir"
  configure_container "$name" "$project_dir"
  sudo nixos-container start "$name"

  echo "Waiting for container to be ready..."
  wait_for_container "$name"

  echo "Done! Container '$name' rebuilt."
}

cmd_logs() {
  local name="${1:-}"
  local lines="${2:-50}"
  local service="${3:-}"
  [[ -z "$name" ]] && { echo "error: container name required" >&2; exit 1; }

  if [[ -n "$service" ]]; then
    container_exec "$name" "" "journalctl -u $service -n $lines --no-pager" "" false
  else
    container_exec "$name" "" "journalctl -n $lines --no-pager" "" false
  fi
}

cmd_status() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "error: container name required" >&2; exit 1; }

  local status
  status=$(sudo nixos-container status "$name" 2>/dev/null || echo "not found")
  echo "Container: $name — $status"

  if [[ "$status" != "running" && "$status" != "up" ]]; then
    return
  fi

  echo ""
  echo "Services:"
  for svc in sshd tailscaled tailscaled-autoconnect opencode-web; do
    local state
    state=$(container_exec "$name" "" "systemctl is-active $svc" "" true)
    printf "  %-30s %s\n" "$svc" "${state:-inactive}"
  done

  echo ""
  echo "Bind mounts:"
  container_exec "$name" "" "findmnt -rn -o TARGET,SOURCE" "" true | grep -v "^/proc\|^/sys\|^/dev" || true

  echo ""
  echo "Tailscale:"
  container_exec "$name" "" "tailscale status --self" "" true || echo "  not connected"
}

get_tailscale_hostname() {
  local name="$1"
  local hostname
  hostname=$(container_exec "$name" "" "hostname" "" true)
  hostname="${hostname//$'\r'/}"
  hostname="${hostname//$'\n'/}"
  
  if [[ -z "$hostname" ]]; then
    return 1
  fi
  
  local parent_domain
  parent_domain=$(container_exec "$name" "" "awk '/^search/ {for(i=1;i<=NF;i++) if(\$i ~ /\./) {print \$i; exit}}' /etc/resolv.conf" "" true)
  parent_domain="${parent_domain//$'\r'/}"
  parent_domain="${parent_domain//$'\n'/}"
  
  if [[ -z "$parent_domain" ]]; then
    echo "error: could not determine Tailscale DNS domain" >&2
    return 1
  fi
  
  printf "%s.%s" "$hostname" "$parent_domain"
}

cmd_url() {
  local name="${1:-}"
  local user="dev"
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user) user="$2"; shift 2 ;;
      -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
      *) name="$1"; shift ;;
    esac
  done
  
  [[ -z "$name" ]] && { echo "error: container name required" >&2; usage; exit 1; }

  local status
  status=$(sudo nixos-container status "$name" 2>/dev/null || echo "not found")

  if [[ "$status" != "running" && "$status" != "up" ]]; then
    echo "Container '$name' is not running. Starting..."
    sudo nixos-container start "$name"
    echo "Waiting for container to be ready..."
    wait_for_container "$name"
  fi

  local hostname
  hostname=$(get_tailscale_hostname "$name")

  if [[ -z "$hostname" ]]; then
    echo "error: could not get container hostname" >&2
    exit 1
  fi

  local project_path="${PROJECT_MOUNT_PATH}${name}"
  local url="vscode://vscode-remote/ssh-remote+${user}@${hostname}${project_path}"

  echo "$url"
}

cmd_exec() {
  local name=""
  local user=""
  local cmd_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user) user="$2"; shift 2 ;;
      --) shift; break ;;
      -*) echo "error: unknown option: $1" >&2; exit 1 ;;
      *)
        if [[ -z "$name" ]]; then
          name="$1"
        else
          cmd_args+=("$1")
        fi
        shift
        ;;
    esac
  done
  # Collect remaining args after --
  cmd_args+=("$@")

  [[ -z "$name" ]] && { echo "error: container name required" >&2; exit 1; }
  [[ ${#cmd_args[@]} -eq 0 ]] && { echo "error: command required" >&2; exit 1; }

  local target
  if [[ -n "$user" ]]; then
    target="$user@$name"
  else
    target="$name"
  fi

  local cmd
  cmd="${cmd_args[*]}"
  container_exec "$name" "$target" "$cmd"
}

# Main dispatch
[[ $# -eq 0 ]] && { usage; exit 1; }

case "$1" in
  create)   shift; cmd_create "$@" ;;
  start)    shift; cmd_start "$@" ;;
  stop)     shift; cmd_stop "$@" ;;
  destroy)  shift; cmd_destroy "$@" ;;
  list)     cmd_list ;;
  shell)    shift; cmd_shell "$@" ;;
  rebuild)  shift; cmd_rebuild "$@" ;;
  rebuildf) shift; cmd_rebuildf "$@" ;;
  logs)     shift; cmd_logs "$@" ;;
  status)   shift; cmd_status "$@" ;;
  url)      shift; cmd_url "$@" ;;
  exec)     shift; cmd_exec "$@" ;;
  -h|--help|help) usage ;;
  *) echo "Unknown command: $1" >&2; usage; exit 1 ;;
esac
