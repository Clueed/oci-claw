{ pkgs, lib, config, ... }:

let
  nanoclawDir = "/home/claw/nanoclaw";
in
{
  sops.secrets.nanoclaw_auth_token = {
    owner = "claw";
  };

  sops.secrets.nanoclaw_telegram_token = {
    owner = "claw";
  };

  sops.templates."nanoclaw.env" = {
    owner = "claw";
    content = ''
    ANTHROPIC_AUTH_TOKEN=${config.sops.placeholder.nanoclaw_auth_token}
    ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic
    TELEGRAM_BOT_TOKEN=${config.sops.placeholder.nanoclaw_telegram_token}
    ASSISTANT_NAME="Andy"
  '';
  };

  system.activationScripts.nanoclaw-env = lib.stringAfter [ "setupSecrets" ] ''
    ln -sf ${config.sops.templates."nanoclaw.env".path} ${nanoclawDir}/.env
  '';

  environment.systemPackages = [
    pkgs.nodejs_22
  ];

  users.users.claw.extraGroups = [ "podman" ];

  home-manager.users.claw = _: {
    xdg.configFile."nanoclaw/mount-allowlist.json".text = builtins.toJSON {
      allowedRoots = [];
      blockedPatterns = [];
      nonMainReadOnly = true;
    };

    systemd.user.services.nanoclaw-container = {
      Unit = {
        Description = "Build NanoClaw Container Image";
        After = [ "default.target" ];
        ConditionPathExists = "${nanoclawDir}/container/Dockerfile";
      };
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.bash}/bin/bash -l -c 'podman image inspect nanoclaw-agent:latest >/dev/null 2>&1 || (cd ${nanoclawDir}/container && podman build -t nanoclaw-agent:latest .)'";
      };
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.nanoclaw = {
      Unit = {
        Description = "NanoClaw Personal Claude Assistant";
        After = [ "network.target" "nanoclaw-container.service" ];
        Wants = [ "nanoclaw-container.service" ];
        ConditionPathExists = "${nanoclawDir}/.env";
      };
      Service = {
        Type = "simple";
        WorkingDirectory = nanoclawDir;
        ExecStartPre = "${pkgs.bash}/bin/bash -l -c 'cd ${nanoclawDir} && npm install --silent && npm run build'";
        ExecStart = "${pkgs.bash}/bin/bash -l -c 'cd ${nanoclawDir} && exec node dist/index.js'";
        Restart = "on-failure";
        RestartSec = "10";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
