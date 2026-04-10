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
  rebuild <name>        Rebuild container after editing .devenv/extra.nix
  rm <name>             Destroy a dev container (project files kept)
  ls                    List dev containers
  shell <name>          Open a shell in a dev container
EOF
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
    GH_TOKEN=$(cat /run/secrets/github_pat 2>/dev/null || true) git clone "$repo_url" "$project_dir"
  else
    mkdir -p "$project_dir"
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

  echo "Locking flake..."
  nix flake lock "$devenv_dir"

  echo "Building and creating container '$name'..."
  sudo nixos-container create "$name" --flake "$devenv_dir"

  # Create /etc/secrets so nspawn can bind-mount secrets into it.
  sudo mkdir -p "/var/lib/nixos-containers/$name/etc/secrets"
  sudo chmod 750 "/var/lib/nixos-containers/$name/etc/secrets"

  # Append bind-mount flags to the container conf file.
  # nixos-container uses EXTRA_NSPAWN_FLAGS which are passed directly to systemd-nspawn,
  # which is more reliable than the .nspawn settings file for file bind-mounts.
  echo "EXTRA_NSPAWN_FLAGS=--bind=$project_dir:/home/dev/$name --bind-ro=/run/secrets/github_pat:/etc/secrets/github_pat --bind-ro=/run/secrets/tailscale_devenv_auth_key:/etc/secrets/ts_auth_key" \
    | sudo tee -a "/etc/nixos-containers/$name.conf" > /dev/null

  echo "Starting container '$name'..."
  sudo nixos-container start "$name"

  echo ""
  echo "Container '$name' is ready."
  echo "  Shell:   devenv shell $name"
  echo "  Project: $project_dir"
  echo "  Config:  $devenv_dir/extra.nix"
  echo "  Services (accessible via Tailscale once registered):"
  echo "    OpenCode:  http://$name.<tailnet>:4096"
  echo "    VS Code:   http://$name.<tailnet>:4000"
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
  local name=${1:?'Usage: devenv rebuild <name>'}
  echo "Rebuilding container '$name'..."
  sudo nixos-container update "$name"
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

case "${1:-}" in
  new)     cmd_new "${2:-}" ;;
  clone)   cmd_clone "${2:-}" "${3:-}" ;;
  rebuild) cmd_rebuild "${2:-}" ;;
  rm)      cmd_rm "${2:-}" ;;
  ls)      cmd_ls ;;
  shell)   cmd_shell "${2:-}" ;;
  *)       usage; exit 1 ;;
esac
