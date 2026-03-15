{
  pkgs,
  lib,
  config,
  ...
}:

let
  nanoclawDir = "/home/claw/nanoclaw";
in
{
  sops.secrets.nanoclaw_anthropic_api_key = {
    owner = "claw";
  };

  sops.secrets.nanoclaw_telegram_token = {
    owner = "claw";
  };

  sops.secrets.nanoclaw_groq_api_key = {
    owner = "claw";
  };

  sops.templates."nanoclaw.env" = {
    owner = "claw";
    content = ''
      ANTHROPIC_API_KEY=${config.sops.placeholder.nanoclaw_anthropic_api_key}
      ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic
      API_TIMEOUT_MS=3000000

      # Not passed currently
      ANTHROPIC_MODEL=glm-4.7
      ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.5-Air
      ANTHROPIC_DEFAULT_SONNET_MODEL=glm-4.7
      ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5
      CLAUDE_CODE_SUBAGENT_MODEL=glm-4.7
      DISABLE_TELEMETRY="1"
      CLAUDE_CODE_ENABLE_TELEMETRY="0"
      CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY="1"
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"
      SKIP_CLAUDE_API="1"

      TELEGRAM_BOT_TOKEN=${config.sops.placeholder.nanoclaw_telegram_token}
      GROQ_API_KEY=${config.sops.placeholder.nanoclaw_groq_api_key}
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
      allowedRoots = [ ];
      blockedPatterns = [ ];
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
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
