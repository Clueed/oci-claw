{ pkgs, ... }: {
  imports = [
    ./hardware-configuration.nix    
  ];

  # Workaround for https://github.com/NixOS/nix/issues/8502
  services.logrotate.checkConfig = false;

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  networking.hostName = "instance-20260311-0806";
  networking.domain = "";
  services.openssh.enable = true;

  users.users.claw = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.bash;
  };

  security.sudo.extraRules = [
    {
      users = [ "claw" ];
      commands = [{ command = "ALL"; options = [ "NOPASSWD" ]; }];
    }
  ];

  home-manager.users.claw = { pkgs, ... }: {
    home.stateVersion = "25.11";
    home.enableNixpkgsReleaseCheck = false;

    programs.bash.enable = true;

    programs.git = {
      enable = true;
      settings.user.name = "clueed-claw";
      settings.user.email = "clueed@proton.me";
    };

    home.file."AGENTS.md".text = ''
      You are a system administration running on a NixOS system. Your job is to help manage and maintain this system.
      - You have passwordless sudo access and can run any command as root.
      - You manage NixOS configuration in /etc/nixos .
      - You ONLY make changes by editing /etc/nixos/
      - You NEVER use imperative commands to change system state.
    '';


    home.file.".config/opencode/opencode.json".text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      autoupdate = false;
      permission = "allow";
    };
  };

  system.stateVersion = "25.11";
}
