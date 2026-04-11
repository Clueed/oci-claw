---
name: devenv
description: Manage NixOS dev containers using the devenv utility
license: MIT
compatibility: claude-code
metadata:
  audience: developers
  workflow: development
---

## What I do

- Create, rebuild, and destroy NixOS dev containers
- List existing containers and open shells in them
- Run commands inside containers as dev user or root
- Print VS Code SSH remote URLs for containers

## IMPORTANT: Always use the `devenv` utility

**Never use `nixos-container`, `machinectl`, or any other tool directly** to manage dev containers.
All container lifecycle operations must go through `devenv`. This ensures bind-mounts, secrets,
project directories, and Tailscale auth are all set up correctly.

## Commands

```bash
# Create a new empty container
devenv new <name>

# Clone a GitHub repo into a new container
devenv clone <url> [name]

# Rebuild container after editing .devenv/extra.nix
devenv rebuild <name>

# Destroy a container (project files in ~/projects/<name> are kept)
devenv rm <name>

# List all containers
devenv ls

# Open an interactive shell in a container
devenv shell <name>

# Run a command as the dev user
devenv exec <name> <cmd> [args...]

# Run a command as root
devenv exec --root <name> <cmd> [args...]

# Print the VS Code SSH remote URL
devenv code <name>
```

## How containers are structured

- **Project directory**: `~/projects/<name>` — bind-mounted into the container at `/home/dev/<name>`
- **Config**: `~/projects/<name>/.devenv/flake.nix` — generated flake (do not edit)
- **Extra packages**: `~/projects/<name>/.devenv/extra.nix` — edit this to add packages/config, then run `devenv rebuild <name>`
- **Secrets** (read-only inside container):
  - `/etc/secrets/github_pat` — GitHub PAT
  - `/etc/secrets/ts_auth_key` — Tailscale auth key
- **Git config**: `/etc/gitconfig` — host git config bind-mounted read-only
- **Web UI**: `http://<name>.<tailnet>:4096` — OpenCode

## Adding packages to a container

Edit `~/projects/<name>/.devenv/extra.nix`:

```nix
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    nodejs_22
    bun
    python3
  ];
}
```

Then rebuild:

```bash
devenv rebuild <name>
```

## When to use me

Use this skill when you need to:
- Create a new isolated development environment
- Add packages or configuration to an existing container
- Troubleshoot or inspect a running container
- Open a container in VS Code or run commands inside one
