# NixOS module for imperative dev environment containers.
# Receives via specialArgs: opencode (flake input), projectName, agent-skills, inputs
{
  pkgs,
  lib,
  opencode,
  projectName,
  agent-skills,
  inputs,
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
    "d ${projectName} 0755 dev dev -"
  ];

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
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
    programs.git = {
      enable = true;
      settings = {
        credential.helper = "!gh auth git-credential";
        safe.directory = "*";
      };
    };
    services.vscode-server.enable = true;

    programs.agent-skills = {
      enable = true;
      sources.anthropic = {
        input = "anthropic-skills";
        subdir = "skills";
      };
      sources.vercel = {
        input = "vercel-agent-browser";
        subdir = "skill";
        idPrefix = "vercel";
      };
      skills.enable = [
        "frontend-design"
        "vercel/agent-browser"
      ];
      targets.opencode.enable = true;
    };
  };

  # Make GH_TOKEN available in interactive shells via the bind-mounted secret
  environment.etc."profile.d/gh-token.sh".text = ''
    export GH_TOKEN=$(cat /etc/secrets/github_pat 2>/dev/null || true)
  '';

  systemd.services.opencode-web = {
    description = "OpenCode Backend API Server";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.bash}/bin/bash -c 'GH_TOKEN=$(cat /etc/secrets/github_pat) OPENCODE_ENABLE_EXA=1 exec ${opencodePkg}/bin/opencode serve --hostname 0.0.0.0 --port 4096'";
      WorkingDirectory = "/home/dev";
      User = "dev";
      Restart = "on-failure";
      Type = "simple";
    };
  };

  system.stateVersion = "25.11";
}
