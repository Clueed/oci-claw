---
name: devenvs
description: Manage NixOS dev environment containers using systemd-nspawn. Use when creating, rebuilding, debugging, or managing devenv containers with the devenv CLI.
license: MIT
compatibility: opencode
metadata:
  audience: developers
  workflow: container-management
---

## What I do

- Create and manage isolated dev environment containers backed by systemd-nspawn
- Rebuild containers with updated NixOS config without losing project data
- Debug container issues: check service status, logs, bind mounts, tailscale
- Execute commands inside containers as root or the dev user

## CLI Reference

Run `devenv --help` for the current command list. The CLI is installed via NixOS and supports:

| Command | Description |
|---------|-------------|
| `devenv create <name>` | Create and start a new dev environment |
| `devenv list` | List all devenv containers and their status |
| `devenv status <name>` | Show container health: services, bind mounts, tailscale |
| `devenv exec <name> -- <cmd>` | Run a command as root inside the container |
| `devenv exec <name> --user dev -- <cmd>` | Run a command as the dev user |
| `devenv rebuild <name>` | Rebuild container from flake (stop/update/start) |
| `devenv rebuildf <name>` | Force rebuild: destroy and recreate |
| `devenv logs <name> [lines] [service]` | Show container journal logs, optionally filtered by service |
| `devenv shell <name>` | Open a root shell in the container |
| `devenv start <name>` / `devenv stop <name>` | Start or stop a container |
| `devenv destroy <name>` | Destroy container (project directory kept) |

## Debugging Workflow

When debugging a container, follow this sequence:

1. `devenv list` — see which containers exist and their status
2. `devenv status <name>` — check key services (sshd, tailscaled, opencode-web), bind mounts, and tailscale connectivity
3. `devenv logs <name> 50 <service>` — check logs for a specific service (e.g., tailscaled, opencode-web)
4. `devenv exec <name> -- systemctl is-active <service>` — verify a service state directly
5. `devenv exec <name> --user dev -- <cmd>` — run commands as the dev user (e.g., check VSCode server)
6. `devenv rebuild <name>` — apply config changes (stop → update → start → wait for ready)
7. `devenv rebuildf <name>` — if rebuild doesn't resolve the issue, force recreate

## Container Architecture

- **Host**: NixOS machine running systemd-nspawn containers
- **Container**: Full NixOS system with a `dev` user (sudo NOPASSWD)
- **Project dir**: Host `/home/claw/projects/<name>` bind-mounted to `/<name>` inside container
- **Secrets**: `/run/secrets/` from host bind-mounted to `/etc/secrets/` in container
- **Tailscale**: Runs in userspace networking mode (`--tun=userspace-networking --state=mem:`)
- **OpenCode**: Backend API server runs as systemd service on port 4096

## Key Services Inside Containers

- `sshd` — SSH server for VSCode Remote connections
- `tailscaled` — Tailscale daemon (userspace networking)
- `tailscaled-autoconnect` — Oneshot service that joins the tailnet using bind-mounted auth key
- `opencode-web` — OpenCode backend API server (port 4096)
- `auto-fix-vscode-server` — User service that patches VSCode Server for NixOS compatibility

## Important Notes

- Always use `devenv` CLI commands instead of raw `nixos-container` or `machinectl` commands
- `machinectl shell` requires absolute paths — `devenv exec` handles this automatically
- Container names must be ≤11 characters (systemd unit name limit)
- The devenv script is installed via NixOS config — changes to `devenvs/devenv.sh` require `nh os switch .` to take effect
- Each container has its own ephemeral Tailscale identity

## When to use me

Use this skill when you need to:
- Create, rebuild, or debug devenv containers
- Check why a service isn't running inside a container
- Investigate tailscale, SSH, or VSCode server connectivity issues
- Execute commands inside a container
- Understand the devenv container architecture
