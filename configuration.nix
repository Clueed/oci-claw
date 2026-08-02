{
  pkgs,
  config,
  hostName,
  opencode,
  claude-code-nix,
  llm-agents,
  authorizedKeys,
  skills-catalog,
  ...
}:

let
  mdCrmDir = "/home/claw/repos/md-crm";
  opencodePkg = opencode.packages.${pkgs.stdenv.hostPlatform.system}.default;
  claudeCodePkg = claude-code-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
  agentBrowserPkg = llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.agent-browser;
  claudeWrapper = pkgs.writeShellScriptBin "claude" ''
    exec ${claudeCodePkg}/bin/claude --dangerously-skip-permissions "$@"
  '';
  # Mints per-container, repo-scoped 1h GitHub App tokens. Run as root by the
  # github-token systemd service/timer; the App private key never enters a container.
  mintGithubToken = pkgs.writeShellApplication {
    name = "mint-github-token";
    runtimeInputs = with pkgs; [
      openssl
      curl
      jq
      git
      coreutils
      systemd
    ];
    text = builtins.readFile ./devenvs/mint-github-token.sh;
  };
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
    ./options.nix
    ./hardware-configuration.nix
    ./containers/stash.nix
    ./containers/nanoclaw.nix
    ./aldi-talk-monitor/aldi-talk-monitor.nix
    ./services/transmission.nix
    ./services/image-gallery.nix
    ./services/samba.nix
  ];

  sops.defaultSopsFile = ./secrets.yaml;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.secrets.github_pat.owner = "claw";
  sops.secrets.tailscale_auth_key = { };
  sops.secrets.tailscale_devenv_auth_key = { };
  # GitHub App credentials for minting per-container tokens. Root-only (0400);
  # never bind-mounted into a container. Add the values with:
  #   sops secrets.yaml   ->  gh_app_id, gh_app_private_key (the App's .pem)
  sops.secrets.gh_app_id = { };
  sops.secrets.gh_app_private_key = { };

  system.activationScripts.ensure-nixos-repo = ensureRepo "Clueed" "oci-claw" "/home/claw/nixos" "";
  system.activationScripts.ensure-nanoclaw-repo =
    ensureRepo "Clueed" "nanoclaw" "/home/claw/nanoclaw"
      "";
  system.activationScripts.ensure-md-crm-repo = ensureRepo "Clueed" "md-crm.git" mdCrmDir ''
    # Podman rootless: container node user needs world-writable dirs to create/edit vault files.
    chmod 777 ${mdCrmDir} ${mdCrmDir}/People
  '';

  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets.tailscale_auth_key.path;
    useRoutingFeatures = "server";
    extraUpFlags = [
      "--advertise-tags=tag:claw"
      "--advertise-exit-node"
    ];
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
        ${pkgs.tailscale}/bin/tailscale serve --service=svc:stash           --https=443 127.0.0.1:${toString config.local.stash.port}
        ${pkgs.tailscale}/bin/tailscale serve --service=svc:torrent-gallery --https=443 127.0.0.1:8766
        ${pkgs.tailscale}/bin/tailscale serve --service=svc:torrent         --https=443 127.0.0.1:9091
        ${pkgs.tailscale}/bin/tailscale serve --service=svc:opencode        --https=443 127.0.0.1:4096
      '';
    };
  };

  boot.enableContainers = true;

  # systemd-nspawn force-mounts a tmpfs on each container's /tmp by default, sized to
  # ~10% of host RAM (its built-in default, nothing we configured). Large builds,
  # downloads, and VS Code server unpacks blow that small cap and get ENOSPC while the
  # disk still has room. SYSTEMD_NSPAWN_TMPFS_TMP=0 disables that auto-mount so /tmp
  # falls through to the container's disk-backed rootfs (/var/lib/nixos-containers/<name>).
  # Set on the container@ template unit so every nixos-container inherits it; honored
  # because container@.service execs systemd-nspawn directly (not via the machinectl
  # wrapper, which ignores this env var — systemd#17863). Takes effect on container restart.
  systemd.services."container@".environment.SYSTEMD_NSPAWN_TMPFS_TMP = "0";

  # Enable NAT and IP forwarding for devenv containers.
  # The ve-+ pattern covers all virtual ethernet interfaces created by nixos-container.
  networking.nat.enable = true;
  networking.nat.internalInterfaces = [ "ve-+" ];

  # Per-container GitHub token provisioning. github-token.service mints a 1h
  # installation token scoped to each running container's repo and writes it into
  # that container's /etc/secrets/github_token. The App private key stays on the
  # host; only the disposable token enters a container. The timer refreshes every
  # running container; devenv.sh mints on demand at create/rebuild via the
  # mint-github-token command on PATH (no per-container systemd units, since
  # /etc/systemd/system is read-only on NixOS).
  systemd.services.github-token = {
    description = "Mint GitHub App tokens for running dev containers";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${mintGithubToken}/bin/mint-github-token";
    };
  };
  systemd.timers.github-token = {
    description = "Refresh GitHub App tokens for dev containers";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Re-mint shortly after a host reboot (tokens expired while off) and then
      # every 45 min, comfortably inside the token's 1h lifetime.
      OnBootSec = "2min";
      OnUnitActiveSec = "45min";
    };
  };

  environment.systemPackages = [
    opencodePkg
    claudeWrapper
    agentBrowserPkg
    mintGithubToken
    pkgs.gh
    pkgs.git
    pkgs.sops
    pkgs.nixos-container
    pkgs.mosh
    pkgs.screen
    pkgs.bun
  ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
    substituters = [
      "https://opencode.cachix.org"
      "https://claude-code.cachix.org"
    ];
    trusted-public-keys = [
      "opencode.cachix.org-1:LdhuFTs/xrlYuchvsF+cOBCgCKEJIcesw9ef06GPlXU="
      "claude-code.cachix.org-1:YeXf2aNu7UTX8Vwrze0za1WEDS+4DuI2kVeWEE4fsRk="
    ];
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

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  networking.hostName = hostName;
  networking.firewall.allowedTCPPorts = [
    22
    51413
  ];
  networking.firewall.allowedUDPPorts = [ 51413 ];
  networking.firewall.allowedUDPPortRanges = [
    {
      from = 60000;
      to = 61000;
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

  users.users.claw = {
    isNormalUser = true;
    linger = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = authorizedKeys;
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

        if [[ -n "$SSH_TTY" && -z "$STY" ]]; then
          exec screen -RD
        fi

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
        - You can run any tool available in nixpkgs via `nix run nixpkgs#<package> -- <args>`. For example, `nix run nixpkgs#jq -- --help` to run jq with arguments.
      '';

      home.file."CLAUDE.md".text = "@AGENTS.md";

      home.file.".config/opencode/opencode.json".text = builtins.toJSON {
        "$schema" = "https://opencode.ai/config.json";
        autoupdate = false;
        permission = "allow";
        provider = {
          openrouter = {
            setCacheKey = true;
            timeout = 300000;
            options = {
              headers = {
                "X-OpenRouter-Cache" = "true";
              };
            };
            models = {
              "deepseek/deepseek-v4-flash" = {
                options = {
                  provider = {
                    ignore = [ "alibaba" ];
                    allow_fallbacks = true;
                  };
                };
              };
            };
          };
        };
      };

      systemd.user.services.opencode-web = {
        Unit = {
          Description = "OpenCode Web Interface";
          After = [ "network.target" ];
        };
        Service = {
          ExecStart = "${pkgs.bash}/bin/bash -c '. /etc/set-environment; OPENCODE_ENABLE_EXA=1 exec ${opencodePkg}/bin/opencode web --hostname 127.0.0.1 --port 4096'";
          WorkingDirectory = "/home/claw";
          Restart = "always";
          RestartSec = "5s";
          Type = "simple";
          KillSignal = "SIGTERM";
          StandardInput = "null";
        };
        Install.WantedBy = [ "default.target" ];
      };
    };

  system.stateVersion = "25.11";
}
