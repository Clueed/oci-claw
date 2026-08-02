# System-wide parameters. Anything more than one module has to agree on lives
# here, so a port or endpoint is defined once and read from config everywhere.
{ lib, config, ... }:

let
  inherit (lib) mkOption types;
  cfg = config.local.stash;
in
{
  options.local.stash = {
    port = mkOption {
      type = types.port;
      default = 9999;
      description = ''
        Port the stash container serves its web UI and GraphQL API on.
        Published on loopback only; reached from outside via Tailscale Serve.
      '';
    };

    url = mkOption {
      type = types.str;
      default = "http://127.0.0.1:${toString cfg.port}/graphql";
      defaultText = "http://127.0.0.1:\${port}/graphql";
      description = "Stash GraphQL endpoint. No auth -- loopback only.";
    };

    vfsRcPort = mkOption {
      type = types.port;
      default = 5572;
      description = ''
        Port of the rclone remote control for the VFS mount that backs stash's
        library. Published on loopback only, unauthenticated (--rc-no-auth).
      '';
    };

    vfsRcUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:${toString cfg.vfsRcPort}";
      defaultText = "http://127.0.0.1:\${vfsRcPort}";
      description = ''
        Base URL of that rclone rc. Writers that copy straight to the remote
        POST vfs/refresh here so the mount's directory cache is dropped before
        stash scans.
      '';
    };
  };
}
