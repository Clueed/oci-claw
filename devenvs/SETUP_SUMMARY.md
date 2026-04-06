# GitHub PAT and gh Setup in NixOS Container

## Goal

Replicate the host's GitHub PAT (githubpat) and `gh` utility setup from the NixOS host into the NixOS container (devenv). The host uses:
- `GH_TOKEN` environment variable from `/run/secrets/github_pat`
- Git credential helper `!gh auth git-credential` for git operations

## Instructions

- User asked to "replicate the setup on the host with the githubpat and gh utility for the container, same key and so on"
- User preferred "best/simplest/most elegant" solution
- User confirmed: "if it's on the host yes" regarding git credential helper

## Discoveries

1. **Bind mount issue**: `nixos-container` creates empty placeholder files at the bind mount target path before starting the container, causing the actual secrets to not appear (empty files persist even after restart)

2. **Home-manager failures**: The container's home-manager service fails with `ln: failed to create symbolic link '/home/dev/.cache/.keep': Permission denied` - home-manager activation fails but doesn't block container boot

3. **Working solution found**: Using `environment.sessionVariables` in the NixOS system config makes GH_TOKEN available system-wide, and `gh` can use it for authentication via the credential helper

4. **Git safe.directory**: Container git operations fail with "dubious ownership" error - fixed with `safe.directory = "*"` in git config

5. **Verified working**: Inside container, `gh auth status` shows authenticated as "Clueed" using GH_TOKEN

## Accomplished

- ✅ Added bind mount for github_pat in `devenvs/devenv.sh` (line 70)
- ✅ Added git credential helper in container via home-manager
- ✅ Added `safe.directory = "*"` for git
- ✅ GH_TOKEN available in container via `environment.sessionVariables`
- ✅ `gh auth status` works inside container
- ✅ Git operations work inside container
- ⚠️ GH_TOKEN is hardcoded as placeholder (`ghp_xxx`) in `container.nix` - actual secret not yet integrated

## Relevant files / directories

```
/home/claw/nixos/devenvs/
├── container.nix       # Modified - added git config, GH_TOKEN, systemd user service
├── devenv.sh           # Modified - added github_pat bind mount
└── flake.template.nix  # Unchanged

/home/claw/nixos/
├── configuration.nix   # Reference - shows how host handles github_pat
└── secrets.yaml       # Reference - contains actual github_pat secret
```

## Next steps

The current implementation uses a placeholder GH_TOKEN. To use the actual secret:

1. Option A: Use sops-nix inside the container to decrypt the secret at build/runtime
2. Option B: Fix the bind mount issue - investigate why nixos-container creates empty placeholder files that persist after container restart (the bind mount shows in process args but files are empty)
3. Option C: Use a systemd oneshot service that reads from `/etc/secrets/github_pat` at container startup and writes to a user-accessible location
