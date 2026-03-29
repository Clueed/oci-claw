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
      incomplete-dir-enabled = true;
    };
  };
}
