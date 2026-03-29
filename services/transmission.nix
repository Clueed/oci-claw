{ pkgs, ... }:
{
  services.transmission = {
    enable = true;
    package = pkgs.transmission_4;
    openRPCPort = true;
    openPeerPorts = true;
    settings = {
      rpc-bind-address = "0.0.0.0";
      rpc-authentication-required = false;
      rpc-whitelist-enabled = false;
      rpc-host-whitelist-enabled = false;
      incomplete-dir-enabled = true;
      speed-limit-up = 300; # KB/s (~2.4 Mbps)
      speed-limit-up-enabled = true;
      peer-limit-global = 75;
      peer-limit-per-torrent = 25;
    };
  };
}
