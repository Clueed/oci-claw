#!/usr/bin/env bash
set -euo pipefail

PROJECTS_DIR="$HOME/projects"
NIXOS_DIR="/home/claw/nixos"

usage() {
  cat <<EOF
Usage: devenv <command> [args]

Commands:
  new <name>            Create a new empty dev container
  clone <url> [name]    Clone a GitHub repo into a dev container
  rebuild [--restart] <name>  Rebuild container after editing .devenv/extra.nix
  rm <name>             Destroy a dev container (project files kept)
  ls                    List dev containers
  shell <name>          Open a shell in a dev container
  exec [--root] <name> <cmd>  Run a command in a dev container (default: dev user)
  code <name>           Print VS Code SSH remote URL for the container
EOF
}

# Build and write EXTRA_NSPAWN_FLAGS to the container conf.
# Mode "append" adds a new line (used at creation); "replace" updates the existing line (used at rebuild).
_write_nspawn_flags() {
  local name=$1
  local project_dir=$2
  local mode=$3

  local base_flags="--bind=$project_dir:/home/dev/$name --bind-ro=/run/secrets/github_pat:/etc/secrets/github_pat --bind-ro=/home/claw/.config/git/config:/etc/gitconfig --bind-ro=/run/secrets/tailscale_devenv_auth_key:/etc/secrets/ts_auth_key --bind-ro=/home/claw/.local/share/opencode/auth.json:/home/dev/.local/share/opencode/auth.json --bind-ro=/home/claw/.claude/.credentials.json:/home/dev/.claude/.credentials.json"

  local extra_flags=""
  local flags_file="$project_dir/.devenv/nspawn-flags"
  if [ -f "$flags_file" ]; then
    extra_flags=$(sed '/^[[:space:]]*#/d' "$flags_file" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  fi

  local all_flags="$base_flags${extra_flags:+ $extra_flags}"
  local conf="/etc/nixos-containers/$name.conf"

  if [ "$mode" = "replace" ]; then
    sudo sed -i "s|^EXTRA_NSPAWN_FLAGS=.*|EXTRA_NSPAWN_FLAGS=$all_flags|" "$conf"
  else
    echo "EXTRA_NSPAWN_FLAGS=$all_flags" | sudo tee -a "$conf" > /dev/null
  fi
}

_create_container() {
  local name=$1
  local repo_url=${2:-}
  local project_dir="$PROJECTS_DIR/$name"
  local devenv_dir="$project_dir/.devenv"

  if sudo test -d "/var/lib/nixos-containers/$name" 2>/dev/null; then
    echo "error: container '$name' already exists" >&2
    exit 1
  fi

  # Set up project directory
  if [ -n "$repo_url" ]; then
    echo "Cloning $repo_url into $project_dir..."
    git clone "$repo_url" "$project_dir"
  else
    mkdir -p "$project_dir"
    git -C "$project_dir" init -q
  fi

  mkdir -p "$devenv_dir"

  # Generate .devenv/flake.nix
  cat > "$devenv_dir/flake.nix" <<FLAKE
{
  description = "Dev environment: $name";

  inputs.nixos.url = "path:$NIXOS_DIR";

  outputs =
    { nixos, ... }:
    {
      nixosConfigurations.container = nixos.lib.mkContainer {
        name = "$name";
        extraModules = if builtins.pathExists ./extra.nix then [ ./extra.nix ] else [ ];
      };
    };
}
FLAKE

  # Generate .devenv/extra.nix template
  cat > "$devenv_dir/extra.nix" <<'EXTRA'
# Add extra packages and configuration for this dev environment.
# Run `devenv rebuild <name>` after making changes.
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    # Examples: bun nodejs_22 python3 rustup go
  ];
}
EXTRA

  # Generate .devenv/nspawn-flags template
  cat > "$devenv_dir/nspawn-flags" <<'FLAGS'
# Extra systemd-nspawn flags for this container (one per line, comments ignored).
# Run `devenv rebuild <name>` after making changes.
# Example: --bind=/mnt/stash-data:/mnt/stash-data
FLAGS

  # Stage .devenv files so Nix can evaluate them (it refuses untracked files in git repos).
  git -C "$project_dir" add "$devenv_dir"

  echo "Locking flake..."
  nix flake lock "$devenv_dir"

  echo "Building and creating container '$name'..."
  sudo nixos-container create "$name" --flake "$devenv_dir"

  # Unstage so we don't pollute the project's git index.
  git -C "$project_dir" reset HEAD "$devenv_dir" 2>/dev/null || true

  # Create /etc/secrets so nspawn can bind-mount secrets into it.
  sudo mkdir -p "/var/lib/nixos-containers/$name/etc/secrets"
  sudo chmod 750 "/var/lib/nixos-containers/$name/etc/secrets"

  # Create opencode auth dir so nspawn can bind-mount auth.json into it.
  sudo mkdir -p "/var/lib/nixos-containers/$name/home/dev/.local/share/opencode"

  # Create claude auth dir so nspawn can bind-mount .credentials.json into it.
  sudo mkdir -p "/var/lib/nixos-containers/$name/home/dev/.claude"

  # Write EXTRA_NSPAWN_FLAGS (base flags + any declared in .devenv/nspawn-flags).
  _write_nspawn_flags "$name" "$project_dir" append

  echo "Starting container '$name'..."
  sudo nixos-container start "$name"

  echo ""
  echo "Container '$name' is ready."
  echo "  Shell:    devenv shell $name"
  echo "  Project:  $project_dir"
  echo "  Config:   $devenv_dir/extra.nix"
  echo "  VS Code:  $(cmd_code "$name")"
  echo "  OpenCode: http://$name.<tailnet>:4096"
}

cmd_new() {
  local name=${1:?'Usage: devenv new <name>'}
  _create_container "$name" ""
}

cmd_clone() {
  local url=${1:?'Usage: devenv clone <url> [name]'}
  local name=${2:-$(basename "$url" .git)}
  _create_container "$name" "$url"
}

cmd_rebuild() {
  local restart=0
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --restart) restart=1; shift ;;
      *) echo "error: unknown option '$1'" >&2; exit 1 ;;
    esac
  done
  local name=${1:?'Usage: devenv rebuild [--restart] <name>'}
  local project_dir="$PROJECTS_DIR/$name"
  local devenv_dir="$project_dir/.devenv"
  echo "Rebuilding container '$name'..."
  git -C "$project_dir" add .devenv
  nix flake update --flake "$devenv_dir"
  sudo nixos-container update "$name"
  git -C "$project_dir" reset HEAD .devenv 2>/dev/null || true
  _write_nspawn_flags "$name" "$project_dir" replace
  if [[ $restart -eq 1 ]]; then
    echo "Restarting container '$name'..."
    sudo nixos-container stop "$name"
    sudo nixos-container start "$name"
  else
    echo "  Note: bind-mount changes require a full restart: devenv rebuild --restart $name"
  fi
  echo "  VS Code:  $(cmd_code "$name")"
}

cmd_rm() {
  local name=${1:?'Usage: devenv rm <name>'}
  echo "Destroying container '$name'..."
  sudo nixos-container stop "$name" 2>/dev/null || true
  sudo nixos-container destroy "$name"
  sudo rm -f "/etc/systemd/nspawn/$name.nspawn"
  echo "Container '$name' destroyed. Project files at $PROJECTS_DIR/$name are kept."
}

cmd_ls() {
  local found=0
  for dir in "$PROJECTS_DIR"/*/; do
    [ -d "$dir/.devenv" ] || continue
    echo "$(basename "$dir")"
    found=1
  done
  [ $found -eq 1 ] || echo "(no dev containers)"
}

cmd_shell() {
  local name=${1:?'Usage: devenv shell <name>'}
  sudo nixos-container login "$name"
}

cmd_exec() {
  local root=0
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --root) root=1; shift ;;
      *) echo "error: unknown option '$1'" >&2; exit 1 ;;
    esac
  done
  local name=${1:?'Usage: devenv exec [--root] <name> <cmd> [args...]'}
  shift
  if [[ $root -eq 1 ]]; then
    sudo nixos-container run "$name" -- "$@"
  else
    local cmd
    cmd=$(printf '%q ' "$@")
    sudo nixos-container run "$name" -- /run/wrappers/bin/su -l dev -c "$cmd"
  fi
}

cmd_code() {
  local name=${1:?'Usage: devenv code <name>'}
  # Ask the container for its own MagicDNS FQDN — handles cases where the
  # Tailscale hostname differs from the container name (e.g. pmv-gen-2 vs pmv-gen).
  local host
  host=$(sudo nixos-container run "$name" -- sh -c 'tailscale status --json | jq -r ".Self.DNSName" | sed s/\\.$//' 2>/dev/null) || true
  if [ -z "$host" ]; then
    host="$name"
  fi
  echo "vscode://vscode-remote/ssh-remote+dev@${host}/home/dev/${name}"
}

case "${1:-}" in
  new)     cmd_new "${2:-}" ;;
  clone)   cmd_clone "${2:-}" "${3:-}" ;;
  rebuild) cmd_rebuild "${2:-}" ;;
  rm)      cmd_rm "${2:-}" ;;
  ls)      cmd_ls ;;
  shell)   cmd_shell "${2:-}" ;;
  exec)    cmd_exec "${@:2}" ;;
  code)    cmd_code "${2:-}" ;;
  *)       usage; exit 1 ;;
esac
