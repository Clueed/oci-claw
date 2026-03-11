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
 = "23.11";
}
