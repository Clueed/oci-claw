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
    };
  };
}
