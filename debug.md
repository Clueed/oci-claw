# Troubleshooting nvm Error in NixOS Container Rebuild

## Goal

The user is troubleshooting why `nvm` error persists in a NixOS container rebuild even after removing the nvm package from the configuration.

## Instructions

- User explicitly said: "Don't fix anything just tell me why"
- User instructed to run commands: `nh os switch .` then `devenv rebuild pmv-gen-2`

## Discoveries

1. The error message shows: `undefined variable 'nvm' at .../devenvs/container.nix:95:5`
2. The current `container.nix` in the working tree does NOT contain nvm - it has nodejs, pnpm, bun instead
3. The project's `.devenv/flake.lock` pins the nixos input to a specific narHash: `sha256-w2jbWHjzCf9qVrVJQqMTy7R3dAU87KSmlLCLS1bf9Rc` with `lastModified=1775842364`
4. This locked version still contains nvm at line 95, which is why the rebuild fails
5. The lock file was generated BEFORE the user's changes to remove nvm were made
6. **Root cause**: The project's flake.lock is cached to an old version of the nixos flake that still has nvm

## Accomplished

- Identified the root cause of the nvm error
- Explained that the lock file needs to be updated with `nix flake update` to pick up the changes
- Did NOT fix anything as per user instruction

## Relevant files / directories

- `/home/claw/nixos/devenvs/container.nix` - Main container config (modified, nvm removed)
- `/home/claw/projects/pmv-gen-2/.devenv/flake.nix` - Project's devenv flake
- `/home/claw/projects/pmv-gen-2/.devenv/flake.lock` - Lock file (needs update)
- `/home/claw/projects/pmv-gen-2/.devenv/extra.nix` - Project's extra modules (empty, no nvm)
- `/home/claw/nixos/devenvs/devenv.sh` - Script for managing containers

## Next Step

Run `nix flake update` in `/home/claw/projects/pmv-gen-2/.devenv/` to update the lock file, then retry `devenv rebuild pmv-gen-2`.