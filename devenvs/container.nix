# Base NixOS module for dev environment containers.
# Receives via specialArgs: name (project name), opencode (flake input)
# Project directory is bind-mounted from host via /etc/systemd/nspawn/<name>.nspawn.
{ pkgs, name, opencode, ... }:
let
  opencodePkg = opencode.packages.${pkgs.stdenv.hostPlatform.system}.default;
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
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDEgSlTSA2aHaw/e7Nbut9WL75v3cQLu1zOP+zGOuRWwqZ0UvmGbJSKwc5nDrxwR+L6KoVJxiHx/MftWtYVQe/gGjFYsQTVyLCyRp59RWJMjFFRQaLpN4bn+RhzckSW2PiqAtSyZTaqSQ/DQ79AA1OJkp9+nBhX0RB2Qstr0Ce0F6JJJi3a3wGKECDTdzrv4f02BAbtTSzIPp5fT4jNbvQL+XC75aGZySMuaz1QIgTep8I+Uql/qxU4Id4Q5ADXQRxxDxEFYyG1oyq0+gXmKEhvVOd0CYij/Nrm5ZyrHBR22x6V7q/GP61N7Y/4/NigCh/QwmWmsnBdHGztNgtdEut9nfqVdi51My/5zm0B2ogVH80zXYe4BuNIjjfyg0t/XpJYFJ2pfXDTD+JesZKyOjCuQLrZg296AneoevTG46Dzs3lZZBiA7chAuMr5OpJ1cYsmOYV+eC+X1NfCz+jrlQKELXsOFzd8kYWeZteA+28aN0ZP/T/gNTKzIszcXMyLoxLwVlzlto/GORgwripwVMZJoB3rsjPdAzJh55KcRpCL4xTuZuCd+F6I/QqSRuwdmFgbms9Z/u5HEPzmYl6h/yASnHg0gfHlma5y184AyFJfjbX4tpF+QbZhXaQxLEHx7hwVXIwaglq9SkyNlB9TfnwUjGVLJauLXY3PcZcAFvb9qw== markvavulov@Marks-MBP.fritz.box"
    ];
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

  # Retry tailscale auth after failure so it reconnects once the network is actually up.
  systemd.services.tailscaled-autoconnect.serviceConfig.Restart = "on-failure";
  systemd.services.tailscaled-autoconnect.serviceConfig.RestartSec = "10s";

  # VS Code server accessible via Tailscale on port 4000.
  # withoutConnectionToken: Tailscale is the auth boundary.
  services.openvscode-server = {
    enable = true;
    host = "0.0.0.0";
    port = 4000;
    withoutConnectionToken = true;
    user = "dev";
    group = "users";
  };

  environment.systemPackages = with pkgs; [
    bash
    git
    gh
    curl
    jq
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
