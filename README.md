# oci-claw

## Bootstrap

1. Install NixOS with minimal config
2. Place SSH host key (Bitwarden: "OCICLAW SSH Key") — sops-nix needs it to decrypt secrets:
   ```bash
   cat > /etc/ssh/ssh_host_ed25519_key << 'EOF'
   <paste from Bitwarden>
   EOF
   chmod 600 /etc/ssh/ssh_host_ed25519_key
   ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key > /etc/ssh/ssh_host_ed25519_key.pub
   ```
3. Clone and rebuild:
   ```bash
   nix-shell -p git --run 'git clone https://github.com/Clueed/oci-claw /home/claw/nixos'
   sudo nixos-rebuild switch --flake /home/claw/nixos#ociclaw-1
   ```

Update hostname in `flake.nix`/`configuration.nix` and disk UUIDs in `hardware-configuration.nix` if on new hardware.
