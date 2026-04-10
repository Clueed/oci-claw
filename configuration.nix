{
  pkgs,
  config,
  opencode,
  skills-catalog,
  ...
}:

let
  mdCrmDir = "/home/claw/repos/md-crm";
  opencodePkg = opencode.packages.${pkgs.stdenv.hostPlatform.system}.default;
  ensureRepo = owner: repo: dest: postClone: ''
    if [ ! -d ${dest}/.git ]; then
      mkdir -p $(dirname ${dest})
      /run/wrappers/bin/su - claw -c 'GH_TOKEN=$(cat /run/secrets/github_pat) ${pkgs.git}/bin/git clone https://github.com/${owner}/${repo} ${dest}'
      ${postClone}
    fi
  '';
in
{
  imports = [
    ./hardware-configuration.nix
    ./containers/stash.nix
    ./containers/nanoclaw.nix
    ./aldi-talk-monitor/aldi-talk-monitor.nix
    ./services/transmission.nix
    ./services/image-gallery.nix
  ];

  sops.defaultSopsFile = ./secrets.yaml;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.secrets.github_pat.owner = "claw";
  sops.secrets.tailscale_auth_key = { };
  sops.secrets.tailscale_devenv_auth_key = { };

  system.activationScripts.ensure-nixos-repo   = ensureRepo "Clueed" "oci-claw"    "/home/claw/nixos"    "";
  system.activationScripts.ensure-nanoclaw-repo = ensureRepo "Clueed" "nanoclaw"    "/home/claw/nanoclaw" "";
  system.activationScripts.ensure-md-crm-repo   = ensureRepo "Clueed" "md-crm.git" mdCrmDir ''
    # Podman rootless: container node user needs world-writable dirs to create/edit vault files.
    chmod 777 ${mdCrmDir} ${mdCrmDir}/People
  '';

  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets.tailscale_auth_key.path;
    extraUpFlags = [ "--advertise-tags=tag:claw" ];
  };

  systemd.services.tailscale-serve = {
    description = "Tailscale Serve";
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "tailscale-serve" ''
        ${pkgs.tailscale}/bin/tailscale serve --service=svc:stash           --https=443 127.0.0.1:9999
        ${pkgs.tailscale}/bin/tailscale serve --service=svc:torrent-gallery --https=443 127.0.0.1:8766
        ${pkgs.tailscale}/bin/tailscale serve --service=svc:torrent         --https=443 127.0.0.1:9091
        ${pkgs.tailscale}/bin/tailscale serve --service=svc:opencode        --https=443 127.0.0.1:4096
      '';
    };
  };

  boot.enableContainers = true;

  # Enable NAT and IP forwarding for devenv containers.
  # The ve-+ pattern covers all virtual ethernet interfaces created by nixos-container.
  networking.nat.enable = true;
  networking.nat.internalInterfaces = [ "ve-+" ];
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  environment.systemPackages = [
    opencodePkg
    pkgs.gh
    pkgs.git
    pkgs.sops
    pkgs.nixos-container
  ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
    substituters = [ "https://opencode.cachix.org" ];
    trusted-public-keys = [ "opencode.cachix.org-1:LdhuFTs/xrlYuchvsF+cOBCgCKEJIcesw9ef06GPlXU=" ];
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  nixpkgs.config.allowUnfree = true;

  programs.nh = {
    enable = true;
    flake = "/home/claw/nixos";
  };

  services.logrotate.checkConfig = false;

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  networking.hostName = "ociclaw-1";
  networking.firewall.allowedTCPPorts = [
    22
    51413
  ];
  networking.firewall.allowedUDPPorts = [ 51413 ];
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  users.users.claw = {
    isNormalUser = true;
    linger = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDEgSlTSA2aHaw/e7Nbut9WL75v3cQLu1zOP+zGOuRWwqZ0UvmGbJSKwc5nDrxwR+L6KoVJxiHx/MftWtYVQe/gGjFYsQTVyLCyRp59RWJMjFFRQaLpN4bn+RhzckSW2PiqAtSyZTaqSQ/DQ79AA1OJkp9+nBhX0RB2Qstr0Ce0F6JJJi3a3wGKECDTdzrv4f02BAbtTSzIPp5fT4jNbvQL+XC75aGZySMuaz1QIgTep8I+Uql/qxU4Id4Q5ADXQRxxDxEFYyG1oyq0+gXmKEhvVOd0CYij/Nrm5ZyrHBR22x6V7q/GP61N7Y/4/NigCh/QwmWmsnBdHGztNgtdEut9nfqVdi51My/5zm0B2ogVH80zXYe4BuNIjjfyg0t/XpJYFJ2pfXDTD+JesZKyOjCuQLrZg296AneoevTG46Dzs3lZZBiA7chAuMr5OpJ1cYsmOYV+eC+X1NfCz+jrlQKELXsOFzd8kYWeZteA+28aN0ZP/T/gNTKzIszcXMyLoxLwVlzlto/GORgwripwVMZJoB3rsjPdAzJh55KcRpCL4xTuZuCd+F6I/QqSRuwdmFgbms9Z/u5HEPzmYl6h/yASnHg0gfHlma5y184AyFJfjbX4tpF+QbZhXaQxLEHx7hwVXIwaglq9SkyNlB9TfnwUjGVLJauLXY3PcZcAFvb9qw== markvavulov@Marks-MBP.fritz.box"
    ];
  };

  security.sudo.extraRules = [
    {
      users = [ "claw" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  home-manager.useGlobalPkgs = true;
  home-manager.users.claw =
    { pkgs, ... }:
    {
      imports = [
        skills-catalog.homeManagerModules.default
      ];

      home.stateVersion = "25.11";

      home.sessionVariables = {
        EDITOR = "vi";
        VISUAL = "vi";
      };

      home.packages = [
        pkgs.vim

        (pkgs.writeShellScriptBin "devenv" (builtins.readFile ./devenvs/devenv.sh))

        (pkgs.writeShellScriptBin "nh" ''
          case "$1 $2" in
            "os switch"|"os test"|"os boot"|"os build"|"os build-vm"|\
            "home switch"|"home test"|"home boot"|"home build"|\
            "darwin switch"|"darwin test"|"darwin boot"|"darwin build")
              exec ${pkgs.nh}/bin/nh "$1" "$2" --no-nom "''${@:3}"
              ;;
            *)
              exec ${pkgs.nh}/bin/nh "$@"
              ;;
          esac
        '')
      ];

      programs.bash.enable = true;
      programs.bash.initExtra = ''
        export GH_TOKEN=$(cat /run/secrets/github_pat 2>/dev/null || true)

        opencode() {
          if [ $# -eq 0 ]; then
            command opencode attach http://localhost:4096
          else
            command opencode "$@"
          fi
        }
      '';

      programs.git = {
        enable = true;
        settings = {
          user.name = "clueed-claw";
          user.email = "clueed@proton.me";
          credential.helper = "!gh auth git-credential";
        };
      };

      home.file."AGENTS.md".text = ''
        You are a system administration running on a NixOS system. Your job is to help manage and maintain this system.
        - You have passwordless sudo access and can run any command as root.
        - You manage NixOS configuration in /home/claw/nixos .
        - You ONLY make changes by editing /home/claw/nixos/
        - You NEVER use imperative commands to change system state.
      '';

      home.file."CLAUDE.md".text = "@AGENTS.md";

      home.file.".config/opencode/opencode.json".text = builtins.toJSON {
        "$schema" = "https://opencode.ai/config.json";
        autoupdate = false;
        permission = "allow";
      };

      systemd.user.services.opencode-web = {
        Unit = {
          Description = "OpenCode Web Interface";
          After = [ "network.target" ];
        };
        Service = {
          # Use login shell to source /etc/profile → /etc/set-environment for full NixOS PATH
          # This ensures spawned shells have access to system packages like gh for git credential helper
          ExecStart = "${pkgs.bash}/bin/bash -l -c 'OPENCODE_ENABLE_EXA=1 exec ${opencodePkg}/bin/opencode web --hostname 127.0.0.1 --port 4096'";
          WorkingDirectory = "/home/claw";
          Restart = "on-failure";
          Type = "simple";
        };
        Install.WantedBy = [ "default.target" ];
      };
    };

  system.stateVersion = "25.11";
}
