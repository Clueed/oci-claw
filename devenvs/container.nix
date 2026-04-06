# NixOS module for imperative dev environment containers.
# Receives via specialArgs: opencode (flake input), opencodePort, projectName
{
  pkgs,
  lib,
  opencode,
  opencodePort,
  projectName,
  ...
}:
let
  system = pkgs.stdenv.hostPlatform.system;
  opencodePkg = opencode.packages.${system}.default;
in
{
  boot.isNspawnContainer = true;

  networking.hostName = projectName;
  networking.useDHCP = false;

  users.users.dev = {
    isNormalUser = true;
    home = "/home/dev";
    extraGroups = [ "wheel" ];
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

  networking.firewall.allowedTCPPorts = [ opencodePort ];

  services.tailscale = {
    enable = true;
    extraDaemonFlags = [
      "--state=mem:"
      "--tun=userspace-networking"
    ];
  };

  # Auth key is bind-mounted read-only from the host at /etc/secrets/ts_auth_key.
  # Uses a simple service (not oneshot) so it doesn't block multi-user.target boot,
  # avoiding a deadlock where the host veth networking is only configured after the
  # container signals readiness.
  systemd.services.tailscaled-autoconnect = {
    wantedBy = [ "multi-user.target" ];
    after = [
      "tailscaled.service"
      "network-online.target"
    ];
    wants = [
      "tailscaled.service"
      "network-online.target"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 10;
      TimeoutStartSec = 30;
    };
    path = [ pkgs.tailscale ];
    script = ''
      TS_AUTHKEY_FILE="/etc/secrets/ts_auth_key"
      if [ ! -f "$TS_AUTHKEY_FILE" ]; then
        echo "TS_AUTHKEY file not found at $TS_AUTHKEY_FILE" >&2
        exit 1
      fi
      TS_AUTHKEY=$(cat "$TS_AUTHKEY_FILE")
      if [ -z "$TS_AUTHKEY" ]; then
        echo "TS_AUTHKEY is empty" >&2
        exit 1
      fi
      tailscale up --auth-key "$TS_AUTHKEY" --hostname "${projectName}" --force-reauth
    '';
  };

  systemd.tmpfiles.rules = [
    "d /project 0755 dev dev -"
  ];

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
    };
  };

  environment.systemPackages = with pkgs; [
    bash
    git
    gh
    curl
    jq
    nodejs_22
    opencodePkg
  ];

  home-manager.users.dev = _: {
    home.stateVersion = "25.11";
    home.file.".config/opencode/opencode.json".text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      autoupdate = false;
      permission = "allow";
    };
    services.vscode-server.enable = true;
  };

  systemd.services.opencode-web = {
    description = "OpenCode Web Interface";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.bash}/bin/bash -l -c 'exec ${opencodePkg}/bin/opencode web --hostname 0.0.0.0 --port ${toString opencodePort}'";
      WorkingDirectory = "/home/dev";
      User = "dev";
      Restart = "on-failure";
      Type = "simple";
    };
  };

  system.stateVersion = "25.11";
}
