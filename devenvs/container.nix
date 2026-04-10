# Base NixOS module for dev environment containers.
# Receives via specialArgs: name (project name), opencode (flake input)
# Project directory is bind-mounted from host via /etc/systemd/nspawn/<name>.nspawn.
{ pkgs, lib, name, opencode, llm-agents, authorizedKeys, ... }:
let
  opencodePkg = opencode.packages.${pkgs.stdenv.hostPlatform.system}.default;
  agentBrowser = llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.agent-browser;
in
{
  boot.isNspawnContainer = true;

  networking.hostName = name;
  networking.useDHCP = false;

  users.users.dev = {
    isNormalUser = true;
    home = "/home/dev";
    linger = true; # needed for user systemd services (opencode-web) to start at boot
    extraGroups = [ "wheel" ];
    hashedPassword = "!"; # no password login; SSH key only
    openssh.authorizedKeys.keys = authorizedKeys;
  };

  security.sudo.extraRules = [
    {
      users = [ "dev" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # Each container joins Tailscale as an ephemeral node named after the project.
  # Userspace networking avoids /dev/net/tun which isn't available in nspawn containers.
  # Auth key is the container-specific ephemeral key bind-mounted from the host.
  services.tailscale = {
    enable = true;
    authKeyFile = "/etc/secrets/ts_auth_key";
    interfaceName = "userspace-networking";
    # --timeout=30s: tailscale up fails fast if network isn't up yet.
    # The container's ve-* network interface isn't available until AFTER the container sends
    # systemd READY, which only happens after multi-user.target completes. So on first boot
    # tailscale up will fail (no network yet), multi-user.target proceeds, READY is sent,
    # the host brings up the veth interface, then the service retries and connects.
    extraUpFlags = [ "--hostname=${name}" "--timeout=30s" ];
  };

  # The tailscaled-autoconnect service is Type=notify by default, meaning multi-user.target
  # waits for it to send READY (which only happens when Tailscale reaches Running state).
  # In nspawn containers the ve-* veth interface isn't up until AFTER the container sends its
  # own READY, causing a deadlock. Switching to Type=simple lets multi-user.target proceed
  # immediately so the host can bring up the veth, after which Tailscale connects and the
  # service keeps looping until it detects Running state.
  systemd.services.tailscaled-autoconnect.serviceConfig.Type = lib.mkForce "simple";
  systemd.services.tailscaled-autoconnect.serviceConfig.Restart = "on-failure";
  systemd.services.tailscaled-autoconnect.serviceConfig.RestartSec = "10s";

  # VS Code remote server — auto-patches the VS Code server binary downloaded by the client.
  # Runs as a user systemd service; the client connects via SSH over Tailscale.
  services.vscode-server.enable = true;

  environment.systemPackages = with pkgs; [
    bash
    git
    gh
    curl
    jq
    agentBrowser
  ];

  # Make GH_TOKEN available in interactive shells via the bind-mounted secret
  environment.etc."profile.d/gh-token.sh".text = ''
    export GH_TOKEN=$(cat /etc/secrets/github_pat 2>/dev/null || true)
  '';

  # Required for home-manager to work in nixos-container.
  # /etc/secrets is created here so nspawn can bind-mount secrets into it at container start.
  systemd.tmpfiles.rules = [
    "d /nix/var/nix/profiles/per-user/dev 0755 dev users -"
    "d /home/dev 0755 dev users -"
    "d /home/dev/.cache 0755 dev users -"
    "d /etc/secrets 0750 root root -"
  ];

  home-manager.useGlobalPkgs = true;
  home-manager.users.dev = _: {
    home.stateVersion = "25.11";
    programs.git = {
      enable = true;
      settings = {
        credential.helper = "!gh auth git-credential";
        safe.directory = "*";
      };
    };
    # OpenCode web interface accessible via Tailscale on port 4096.
    systemd.user.services.opencode-web = {
      Unit = {
        Description = "OpenCode Web Interface";
        After = [ "network.target" ];
      };
      Service = {
        ExecStart = "${pkgs.bash}/bin/bash -l -c 'OPENCODE_ENABLE_EXA=1 exec ${opencodePkg}/bin/opencode web --hostname 0.0.0.0 --port 4096'";
        WorkingDirectory = "/home/dev";
        Restart = "on-failure";
        Type = "simple";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };

  system.stateVersion = "25.11";
}
