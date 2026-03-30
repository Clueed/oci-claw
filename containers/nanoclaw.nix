{
  pkgs,
  lib,
  config,
  ...
}:

let
  nanoclawDir = "/home/claw/nanoclaw";
  mdCrmDir = "/home/claw/repos/md-crm";
in
{
  sops.secrets.nanoclaw_claude_oauth_token = {
    owner = "claw";
  };

  sops.secrets.nanoclaw_telegram_token = {
    owner = "claw";
  };

  sops.secrets.nanoclaw_groq_api_key = {
    owner = "claw";
  };

  sops.secrets.nanoclaw_todoist_api_key = {
    owner = "claw";
  };

  sops.templates."nanoclaw.env" = {
    owner = "claw";
    content = ''
      CLAUDE_CODE_OAUTH_TOKEN=${config.sops.placeholder.nanoclaw_claude_oauth_token}
      API_TIMEOUT_MS=3000000
      DISABLE_TELEMETRY="1"
      CLAUDE_CODE_ENABLE_TELEMETRY="0"
      CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY="1"
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"

      TELEGRAM_BOT_TOKEN=${config.sops.placeholder.nanoclaw_telegram_token}
      GROQ_API_KEY=${config.sops.placeholder.nanoclaw_groq_api_key}
      TODOIST_API_KEY=${config.sops.placeholder.nanoclaw_todoist_api_key}
      ASSISTANT_NAME="Andy"
      MD_CRM_DIR=${mdCrmDir}
    '';
  };

  system.activationScripts.nanoclaw-env = lib.stringAfter [ "setupSecrets" ] ''
    ln -sf ${config.sops.templates."nanoclaw.env".path} ${nanoclawDir}/.env
  '';

  # Podman rootless maps host uid to root inside containers.
  # IPC subdirectories need world-writable permissions so the container's
  # node user can read/unlink files written by the host.
  system.activationScripts.nanoclaw-ipc-perms = ''
    for dir in ${nanoclawDir}/data/ipc/*/input ${nanoclawDir}/data/ipc/*/messages ${nanoclawDir}/data/ipc/*/tasks; do
      [ -d "$dir" ] && chmod 777 "$dir"
    done
  '';

  environment.systemPackages = [
    pkgs.nodejs_22
  ];

  users.users.claw.extraGroups = [ "podman" ];

  home-manager.users.claw = _: {
    xdg.configFile."nanoclaw/mount-allowlist.json".text = builtins.toJSON {
      allowedRoots = [
        {
          path = mdCrmDir;
          allowReadWrite = true;
          description = "Personal CRM vault";
        }
      ];
      blockedPatterns = [ ];
      nonMainReadOnly = false;
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
        After = [
          "network.target"
          "nanoclaw-container.service"
        ];
        Wants = [ "nanoclaw-container.service" ];
        ConditionPathExists = "${nanoclawDir}/.env";
      };
      Service = {
        Type = "simple";
        WorkingDirectory = nanoclawDir;
        ExecStartPre = "${pkgs.bash}/bin/bash -l -c 'cd ${nanoclawDir} && npm install --legacy-peer-deps --silent && npm run build'";
        ExecStart = "${pkgs.bash}/bin/bash -l -c 'cd ${nanoclawDir} && exec node dist/index.js'";
        Restart = "on-failure";
        RestartSec = "10";
        Environment = [ "CREDENTIAL_PROXY_HOST=127.0.0.1" ];
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
