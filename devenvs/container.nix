# NixOS module for imperative dev environment containers.
# Receives via specialArgs: opencode (flake input), opencodePort, projectName
{
  pkgs,
  opencode,
  opencodePort,
  projectName,
  ...
}:
let
  opencodePkg = opencode.packages.aarch64-linux.default;
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

  systemd.tmpfiles.rules = [
    "d /project 0755 dev dev -"
  ];

  environment.systemPackages = with pkgs; [
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
  };

  systemd.services.opencode-web = {
    description = "OpenCode Web Interface";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.bash}/bin/bash -l -c 'exec ${opencodePkg}/bin/opencode web --hostname 0.0.0.0 --port ${toString opencodePort}'";
      WorkingDirectory = "/project";
      User = "dev";
      Restart = "on-failure";
      Type = "simple";
    };
  };

  system.stateVersion = "25.11";
}
