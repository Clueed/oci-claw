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

## Secrets

Sops-nix with age (SSH host key). Secrets at `/run/secrets/<name>`.

```bash
SOPS_AGE_KEY=$(sudo nix run nixpkgs#ssh-to-age -- -private-key -i /etc/ssh/ssh_host_ed25519_key) sops secrets.yaml
```
