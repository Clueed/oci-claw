# SMB export of ~/projects so a Mac can mount every devenv folder as a Finder
# volume with live, single-source-of-truth edits (same bytes the containers and
# VS Code-remote see, since each container bind-mounts from /home/claw/projects).
#
# Locked to the Tailscale interface only — never exposed to the public internet.
# Connect from macOS Finder with Cmd-K:  smb://ociclaw-1.<tailnet>/projects
#
# The SMB password is provisioned declaratively from a sops secret
# (smb_password) by the activation step at the bottom of this file — Samba keeps
# its own password DB (passdb.tdb, not PAM), so this keeps it reproducible.
{ pkgs, config, ... }:
{
  # Encrypted SMB password for the `claw` Samba account. Set its value with:
  #   SOPS_AGE_KEY=$(sudo nix run nixpkgs#ssh-to-age -- -private-key \
  #     -i /etc/ssh/ssh_host_ed25519_key) \
  #     sops set secrets.yaml '["smb_password"]' '"your-password"'
  sops.secrets.smb_password = { };

  services.samba = {
    enable = true;
    # We open the firewall per-interface below (tailscale0 only), not globally.
    openFirewall = false;
    settings = {
      global = {
        "server string" = "ociclaw";
        "workgroup" = "WORKGROUP";
        "security" = "user";
        # Defense in depth alongside the per-interface firewall rule: only the
        # Tailscale CGNAT range (and loopback) may talk to smbd at all.
        "hosts allow" = "100.64.0.0/10 127.0.0.1";
        "hosts deny" = "0.0.0.0/0";
        # macOS interop: proper Time Machine-style metadata, AppleDouble handling,
        # and suppression of ._ resource-fork litter in the repos.
        "vfs objects" = "catia fruit streams_xattr";
        "fruit:metadata" = "stream";
        "fruit:model" = "MacSamba";
        "fruit:posix_rename" = "yes";
        "fruit:zero_file_id" = "yes";
        "fruit:nfs_aces" = "no";
        "fruit:wipe_intentionally_left_blank_rfork" = "yes";
        "fruit:delete_empty_adfiles" = "yes";
      };
      projects = {
        "path" = "/home/claw/projects";
        "comment" = "All devenv project folders";
        "browseable" = "yes";
        "read only" = "no";
        "valid users" = "claw";
        # Files land owned by claw:users so the containers (which run as the
        # bind-mounted host uid) and VS Code-remote see consistent ownership.
        "force user" = "claw";
        "force group" = "users";
        "create mask" = "0644";
        "directory mask" = "0755";
        # Keep Finder/Spotlight junk out of the repos.
        "veto files" = "/.DS_Store/._*/.Spotlight-V100/.Trashes/";
        "delete veto files" = "yes";
      };
    };
  };

  # smbd (445) reachable only over Tailscale. No WS-Discovery / mDNS daemon:
  # both rely on multicast, which Tailscale (unicast-only overlay) does not
  # carry, so Finder can't auto-discover the host anyway. Connect explicitly
  # to the MagicDNS name and save it as a Finder favourite for one-click access.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 445 ];

  # Apply the sops-managed password to Samba's passdb on every switch/boot.
  # Ordered after "setupSecrets" so /run/secrets/smb_password exists. smbpasswd
  # only edits passdb.tdb (no running smbd needed) and reads the generated
  # /etc/samba/smb.conf, both present at activation time. Idempotent: -a both
  # creates the entry and updates the password on later runs.
  system.activationScripts.samba-password = {
    deps = [ "setupSecrets" ];
    text = ''
      if [ -f ${config.sops.secrets.smb_password.path} ]; then
        pass=$(cat ${config.sops.secrets.smb_password.path})
        printf '%s\n%s\n' "$pass" "$pass" \
          | ${pkgs.samba}/bin/smbpasswd -a -s claw
      fi
    '';
  };
}
