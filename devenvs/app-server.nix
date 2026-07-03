# Declarative "production" app servers for dev containers.
#
# Each entry in `services.appServer.servers.<key>` becomes a systemd *system*
# service named `app-<key>` that runs as the `dev` user from the bind-mounted
# project directory (/home/dev/<name>). It starts on container boot, restarts on
# crash, survives SSH/VS Code logout, and its port is opened in the firewall.
#
# Example (in .devenv/extra.nix):
#
#   services.appServer.servers.prod = {
#     build = "bun run build";                              # optional; runs first
#     command = "bun run preview --port 3000 --host 0.0.0.0";
#     port = 3000;
#     environment.NODE_ENV = "production";
#   };
#
# Logs: `journalctl -u app-prod -f`
{
  config,
  lib,
  pkgs,
  name,
  ...
}:
let
  cfg = config.services.appServer;

  serverModule = lib.types.submodule {
    options = {
      command = lib.mkOption {
        type = lib.types.str;
        example = "bun run preview --port 3000 --host 0.0.0.0";
        description = ''
          Full command line for the long-lived server process, including the
          executable. Run via `bash -c`, so shell features (&&, env expansion)
          work and the binary is resolved against the service PATH (bun, nodejs,
          pnpm are on it by default).
        '';
      };
      build = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "bun run build";
        description = ''
          Optional full command line to run once before the server starts
          (as ExecStartPre). Blocks startup until it completes.
        '';
      };
      port = lib.mkOption {
        type = lib.types.port;
        description = "TCP port the server listens on; opened in the firewall.";
      };
      workingDirectory = lib.mkOption {
        type = lib.types.str;
        default = "/home/dev/${name}";
        description = "Directory the build/command run in.";
      };
      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Extra environment variables for the build and server.";
      };
    };
  };

  mkService = key: srv: {
    name = "app-${key}";
    value = {
      description = "App server: ${key}";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      # Runners the command is likely to invoke, so bare `bun`/`node`/`pnpm` resolve.
      path = [
        pkgs.bun
        pkgs.nodejs
        pkgs.pnpm
      ];
      environment = srv.environment;
      serviceConfig = {
        User = "dev";
        WorkingDirectory = srv.workingDirectory;
        # Run via bash -c: systemd resolves a bare argv[0] against a compile-time
        # search path, not the unit's Environment=PATH, so `bun`/`node` would fail
        # with 203/EXEC. bash resolves them against the PATH we set below.
        ExecStart = "${pkgs.bash}/bin/bash -c ${lib.escapeShellArg srv.command}";
        Restart = "on-failure";
        RestartSec = "5s";
        # Builds (npm install, bundling) can take a while; don't let systemd kill startup.
        TimeoutStartSec = "infinity";
      }
      // lib.optionalAttrs (srv.build != null) {
        ExecStartPre = "${pkgs.bash}/bin/bash -c ${lib.escapeShellArg srv.build}";
      };
    };
  };
in
{
  options.services.appServer.servers = lib.mkOption {
    type = lib.types.attrsOf serverModule;
    default = { };
    description = "Named always-on app servers to run in this container.";
  };

  config = lib.mkIf (cfg.servers != { }) {
    systemd.services = lib.mapAttrs' mkService cfg.servers;
    networking.firewall.allowedTCPPorts = lib.mapAttrsToList (_: srv: srv.port) cfg.servers;
  };
}
