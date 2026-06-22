# NixOS Configuration

- Search web for current NixOS best practices
- Prefer declarative over imperative
- Use home-manager for user packages/dotfiles

## Change Workflow

After making any change, follow this workflow:

1. **Diff** - `nh os switch . --diff always` to preview changes
2. **Confirm** - Summarize changes and get approval
3. **Test** - `nh os test .` and verify system and changes work (fix or discuss if errors)
4. **Commit** - `git add -A && git commit -m "msg"`
5. **Switch** - `nh os switch .`
6. **Push**

## Files

- `configuration.nix` - Main config (includes home-manager)
- `flake.nix` - Flake inputs/outputs

## VS Code remote on containers

**2026-06-22:** VS Code 1.125+/Remote-SSH 0.124+ broke `services.vscode-server` on the
devenv containers. The new client runs an integrity check (`code-server --version`) in a
`.vscode-server/cli/servers/<commit>.staging/` dir *before* moving the server to its final
path. `nixos-vscode-server` only patches the final path, so the unpatched generic `node`
binary fails with "Could not start dynamically linked executable" (code 127).

Workaround: `programs.nix-ld.enable = true` is set in `devenvs/container.nix` (applies to
all containers). nix-ld provides a stub ELF interpreter so the downloaded binaries run
regardless of path.

**Revisit in a few days/weeks:** check whether `nixos-vscode-server`
(github:nix-community/nixos-vscode-server) has been updated to patch the `.staging` dir.
If so, the `programs.nix-ld.enable` line — and possibly `services.vscode-server` and its
flake input — can be removed.

## Secrets

Sops-nix with age (SSH host key). Secrets at `/run/secrets/<name>`.

```bash
SOPS_AGE_KEY=$(sudo nix run nixpkgs#ssh-to-age -- -private-key -i /etc/ssh/ssh_host_ed25519_key) sops secrets.yaml
```
