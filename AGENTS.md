# NixOS Setup

This system uses NixOS with home-manager for declarative configuration management.

## Structure

- `/home/claw/nixos/configuration.nix` - Main NixOS system configuration (includes home-manager)
- `/home/claw/nixos/flake.nix` - Flake inputs and outputs

## Best Practices

- Always use the latest Nix/NixOS best practices - search the web for current recommendations
- Prefer declarative configurations over imperative changes
- Use `home-manager` for user-level package management and dotfiles
- Keep secrets in secrets.nix or use age encryption
- Test changes with `nixos-rebuild test` before applying
- Use `nix flake check` or `nixfmt` for linting

## Change Workflow

1. Summarize the changes to be made
2. Confirm with the user before proceeding
3. Run `sudo nixos-rebuild test` to validate
4. If there are errors, fix them and repeat step 3
5. Once tested successfully: commit and push
6. Run `sudo nixos-rebuild switch` to apply
