# SMB export of ~/projects so a Mac can mount every devenv folder as a Finder
# volume with live, single-source-of-truth edits (same bytes the containers and
# VS Code-remote see, since each container bind-mounts from /home/claw/projects).
#
# Locked to the Tailscale interface only — never exposed to the public internet.
# Connect from macOS Finder with Cmd-K:  smb://ociclaw-1.<tailnet>/projects
#
# One-time credential setup (Samba keeps its own password DB, not PAM):
#   sudo smbpasswd -a claw
{ ... }:
{
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

  # WSDD lets macOS Finder auto-discover the host under "Network" without typing
  # the address. Tailscale-only via the same interface guard.
  services.samba-wsdd = {
    enable = true;
    openFirewall = false;
    interface = "tailscale0";
  };

  # Reachable only over Tailscale: smbd (445), plus WSD discovery (3702/udp, 5357/tcp).
  networking.firewall.interfaces.tailscale0 = {
    allowedTCPPorts = [
      445
      5357
    ];
    allowedUDPPorts = [ 3702 ];
  };
}
