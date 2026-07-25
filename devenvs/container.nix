# Base NixOS module for dev environment containers.
# Receives via specialArgs: name (project name), opencode (flake input)
# Project directory is bind-mounted from host via /etc/systemd/nspawn/<name>.nspawn.
{
  pkgs,
  lib,
  name,
  opencode,
  claude-code-nix,
  llm-agents,
  authorizedKeys,
  skills-catalog,
  ...
}:
let
  opencodePkg = opencode.packages.${pkgs.stdenv.hostPlatform.system}.default;
  claudeCodePkg = claude-code-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
  claudeWrapper = pkgs.writeShellScriptBin "claude" ''
    exec ${claudeCodePkg}/bin/claude --dangerously-skip-permissions "$@"
  '';
  agentBrowser = llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.agent-browser;
  # gh wrapper that reads the current short-lived token from disk on every call,
  # so hourly token rotation is transparent to long-lived processes (opencode-web).
  # The git credential helper (`gh auth git-credential`) resolves to this wrapper too.
  ghWrapper = pkgs.writeShellScriptBin "gh" ''
    export GH_TOKEN=$(cat /etc/secrets/github_token 2>/dev/null || true)
    exec ${pkgs.gh}/bin/gh "$@"
  '';
  # Global agent instructions, shared by OpenCode (AGENTS.md) and Claude Code (CLAUDE.md).
  agentInstructions = ''
    A native browser automation CLI (`agent-browser`) is available for controlling a browser — useful for testing, QA, and web scraping.
    It drives a real browser via an accessibility tree snapshot model: take a snapshot to get element refs, then interact with them.

    See the `agent-browser` skill for usage details.

    This container runs NixOS. Do not use `apt`, `brew`, or other imperative package managers.
    Packages are managed declaratively via Nix; use `nix run nixpkgs#<pkg>` to run a package ad-hoc.
    Arbitrary binaries that assume a standard FHS filesystem layout may not work without patching.

    To permanently add packages, edit `.devenv/extra.nix` in the project root — then ask the user
    to run `devenv rebuild <repo-name>` on the host system to apply the changes.

    **Trunk-based development.** One permanent branch `main`; everything else short-lived (hours to a day). Run the `gh` CLI workflow yourself, don't wait to be told.

    - User starts work? Ask first: "Should I create a branch?" Then `git switch -c type/short-desc` (`feat/`, `fix/`, `chore/`).
    - Keep branches small. Open longer than a day means split it.
    - Commit often, push early, open the PR yourself: `gh pr create --draft` so CI runs.
    - Sync before merging: `git fetch && git rebase origin/main`.
    - Work done? Prompt to land it: "Looks done, squash-merge into `main`?" One PR becomes one commit; let the branch auto-delete.
    - User pivots to something new? Flag it: "Let's merge this first, then branch off fresh `main`."
  '';
in
{
  boot.isNspawnContainer = true;

  networking.hostName = name;
  networking.useDHCP = false;
  networking.firewall.allowedTCPPorts = [ 4096 ];

  users.users.dev = {
    isNormalUser = true;
    home = "/home/dev";
    linger = true; # needed for user systemd services (opencode-web) to start at boot
    extraGroups = [ "wheel" ];
    hashedPassword = "!"; # no password login; SSH key only
    openssh.authorizedKeys.keys = authorizedKeys;
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

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # Each container joins Tailscale as an ephemeral node named after the project.
  # Userspace networking avoids /dev/net/tun which isn't available in nspawn containers.
  # Auth key is the container-specific ephemeral key bind-mounted from the host.
  services.tailscale = {
    enable = true;
    authKeyFile = "/etc/secrets/ts_auth_key";
    interfaceName = "userspace-networking";
    # --timeout=30s: tailscale up fails fast if network isn't up yet.
    # The container's ve-* network interface isn't available until AFTER the container sends
    # systemd READY, which only happens after multi-user.target completes. So on first boot
    # tailscale up will fail (no network yet), multi-user.target proceeds, READY is sent,
    # the host brings up the veth interface, then the service retries and connects.
    extraUpFlags = [
      "--hostname=${name}"
      "--timeout=30s"
      "--operator=dev"
    ];
  };

  # Lower the userspace/netstack MTU so the container's outbound TCP segments stay small
  # enough to survive a DERP-relayed tailnet path. Background: OpenSSH 10.0+ (pulled in via
  # a 2026-07 nixpkgs bump) defaults its key exchange to the post-quantum mlkem768x25519,
  # whose KEX reply is a ~1.2 KB packet -- far larger than the old curve25519 reply. When a
  # client reaches this container over a DERP relay (no direct path), that large packet hit a
  # PMTU black hole and was silently dropped, so SSH hung at "expecting SSH2_MSG_KEX_ECDH_REPLY"
  # and timed out. Small packets (ping, port probe, KEXINIT) always got through. In netstack
  # mode there is no tailscale0 device to `ip link set mtu` on; TS_DEBUG_MTU is the only knob.
  # 1000 leaves generous headroom under the relay path MTU; also protects large HTTP responses
  # (e.g. the tailnet-served stash UI) from the same black hole. Raise if throughput matters.
  systemd.services.tailscaled.environment.TS_DEBUG_MTU = "1000";

  # The tailscaled-autoconnect service is Type=notify by default, meaning multi-user.target
  # waits for it to send READY (which only happens when Tailscale reaches Running state).
  # In nspawn containers the ve-* veth interface isn't up until AFTER the container sends its
  # own READY, causing a deadlock. Switching to Type=simple lets multi-user.target proceed
  # immediately so the host can bring up the veth, after which Tailscale connects and the
  # service keeps looping until it detects Running state.
  # restartIfChanged=false: during `nixos-container update` (switch-to-configuration test),
  # restarting tailscaled-autoconnect runs `tailscale up` which fails transiently (daemon busy
  # or network not ready), causing switch-to-configuration to exit non-zero and the reload to
  # fail with NOPERMISSION. The service is already connected at this point; no restart needed.
  systemd.services.tailscaled-autoconnect.restartIfChanged = false;
  systemd.services.tailscaled-autoconnect.serviceConfig.Type = lib.mkForce "simple";
  # NotifyAccess=main: with Type=simple, $NOTIFY_SOCKET is not set by default, causing the
  # autoconnect script's `systemd-notify --ready` to exit 1 (set -o errexit kills it before
  # `exit 0`). Setting NotifyAccess makes systemd pass $NOTIFY_SOCKET so the notify succeeds.
  systemd.services.tailscaled-autoconnect.serviceConfig.NotifyAccess = lib.mkForce "main";
  systemd.services.tailscaled-autoconnect.serviceConfig.Restart = "on-failure";
  systemd.services.tailscaled-autoconnect.serviceConfig.RestartSec = "10s";

  # VS Code remote server — auto-patches the VS Code server binary downloaded by the client.
  # Runs as a user systemd service; the client connects via SSH over Tailscale.
  services.vscode-server.enable = true;

  environment.systemPackages = with pkgs; [
    bash
    git
    ghWrapper
    curl
    jq
    mosh
    agentBrowser
    opencodePkg
    claudeWrapper
    nodejs
    pnpm
    bun
  ];

  environment.variables.OPENCODE_ENABLE_EXA = "1";

  # GitHub auth is provided by a per-container, repo-scoped, 1h token written to
  # /etc/secrets/github_token by the host's github-token service (see the
  # host configuration.nix). The gh wrapper reads it fresh on every call, so it is
  # deliberately NOT exported as GH_TOKEN into shells (a login-time snapshot would
  # go stale within the hour for long-lived processes).

  # Required for home-manager to work in nixos-container.
  # /etc/secrets is created here so nspawn can bind-mount secrets into it at container start.
  # Intermediate .local and .local/share must be declared so tmpfiles creates them
  # as dev-owned. Otherwise it auto-creates them as root:root while processing the
  # opencode rule, then refuses to fix the leaf with "unsafe path transition".
  systemd.tmpfiles.rules = [
    "d /nix/var/nix/profiles/per-user/dev 0755 dev users -"
    "d /home/dev 0755 dev users -"
    "d /home/dev/.cache 0755 dev users -"
    "d /etc/secrets 0751 root root -"
    "d /home/dev/.local 0755 dev users -"
    "d /home/dev/.local/share 0755 dev users -"
    "d /home/dev/.local/share/opencode 0755 dev users -"
    "d /home/dev/.claude 0755 dev users -"
  ];

  home-manager.useGlobalPkgs = true;
  home-manager.users.dev = _: {
    imports = [ skills-catalog.homeManagerModules.sources ];
    programs.agent-skills.skills.enable = [
      "opencode-history"
      "commit-work"
      "agent-browser"
      "shadcn"
    ];
    home.stateVersion = "25.11";
    # identity comes from the bind-mounted host ~/.gitconfig;
    # credential helper runs the gh wrapper, which reads /etc/secrets/github_token.
    home.file.".config/opencode/AGENTS.md".text = agentInstructions;
    home.file.".claude/CLAUDE.md".text = agentInstructions;
    home.file.".config/opencode/opencode.json".text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      permission = "allow";
      provider = {
        openrouter = {
          setCacheKey = true;
          timeout = 300000;
          options = {
            headers = {
              "X-OpenRouter-Cache" = "true";
            };
          };
        };
      };
    };
    programs.git = {
      enable = true;
      settings = {
        credential.helper = "!gh auth git-credential";
        safe.directory = "*";
      };
    };
    # OpenCode web interface accessible via Tailscale on port 4096.
    systemd.user.services.opencode-web = {
      Unit = {
        Description = "OpenCode Web Interface";
        After = [ "network.target" ];
      };
      Service = {
        ExecStart = "${pkgs.bash}/bin/bash -l -c 'OPENCODE_ENABLE_EXA=1 exec ${opencodePkg}/bin/opencode web --hostname 0.0.0.0 --port 4096'";
        WorkingDirectory = "/home/dev";
        Restart = "on-failure";
        Type = "simple";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };

  system.stateVersion = "25.11";
}
