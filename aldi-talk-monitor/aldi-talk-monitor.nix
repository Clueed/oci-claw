{ pkgs, config, ... }:
{
  sops.secrets.aldi_talk_username.owner = "claw";
  sops.secrets.aldi_talk_password.owner = "claw";

  sops.templates."aldi-talk-monitor.env" = {
    owner = "claw";
    content = ''
      ALDI_TALK_USERNAME=${config.sops.placeholder.aldi_talk_username}
      ALDI_TALK_PASSWORD=${config.sops.placeholder.aldi_talk_password}
    '';
  };

  home-manager.users.claw = _: {
    home.packages = [ pkgs.bun ];

    systemd.user.services.aldi-talk-monitor = {
      Unit.Description = "ALDI TALK data balance checker";
      Service = {
        Type = "oneshot";
        EnvironmentFile = config.sops.templates."aldi-talk-monitor.env".path;
        ExecStart = "${pkgs.bun}/bin/bun run /home/claw/nixos/aldi-talk-monitor/monitor.ts";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    systemd.user.timers.aldi-talk-monitor = {
      Unit.Description = "ALDI TALK data balance checker timer";
      Timer = {
        OnCalendar = "*:0/15";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
