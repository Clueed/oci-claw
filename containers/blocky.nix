# Blocky -- ad/tracker-blocking DNS resolver, reachable on the tailnet as
# blocky.<tailnet>.ts.net.
#
# Why a Tailscale sidecar instead of `tailscale serve --service=svc:blocky`
# (the pattern used for stash/torrent in configuration.nix): Tailscale Services
# and Serve proxy TCP only. DNS is predominantly UDP, so a svc: VIP cannot carry
# it without a layer-3 `--tun` endpoint plus hand-written iptables DNAT rules.
# Running tailscaled in a sidecar gives blocky its own tailnet node with a real
# 100.x address, so UDP/53 works natively and MagicDNS supplies the human
# readable name for free. blocky joins the sidecar's network namespace, so both
# DNS and the web UI are published on that node's tailnet address only -- nothing
# is bound on the host.
#
# After the first switch:
#   - web UI/API:  http://blocky.<tailnet>.ts.net:4000
#   - test:        dig @blocky.<tailnet>.ts.net doubleclick.net   (expect 0.0.0.0)
#   - to make the tailnet use it, set the blocky node's 100.x address as a
#     global nameserver in the Tailscale admin console (DNS -> Nameservers).
#     That step is admin-console only; it cannot be declared here.
{
  pkgs,
  config,
  ...
}:

let
  # Tailnet node name -> blocky.<tailnet>.ts.net via MagicDNS.
  tsHostname = "blocky";
  httpPort = 4000;

  blockyConfig = pkgs.writeText "blocky.yml" ''
    upstreams:
      groups:
        default:
          - 1.1.1.1
          - 9.9.9.9

    # Plain UDP/TCP upstreams above need no bootstrapDns; switch to DoH
    # (https://...) only together with a bootstrapDns entry, or blocky cannot
    # resolve its own upstream's hostname at startup.

    blocking:
      denylists:
        ads:
          - https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
      clientGroupsBlock:
        default:
          - ads
      blockType: zeroIp

    caching:
      minTime: 5m
      maxTime: 30m
      prefetching: true

    ports:
      dns: 53
      http: ${toString httpPort}

    log:
      level: info
  '';
in
{
  # Reuses the host's own tailscale_auth_key -- it is reusable and already
  # carries tag:claw, so the node comes up tagged (and tagged nodes never
  # expire, which is what keeps the resolver alive across key rotations).
  # Deliberately NOT tailscale_devenv_auth_key: that key is tagged
  # tag:claw-devenv, and blocky is a service, not a dev container.
  sops.templates."blocky-ts.env".content = ''
    TS_AUTHKEY=${config.sops.placeholder.tailscale_auth_key}
  '';

  virtualisation.oci-containers.containers.blocky-ts = {
    image = "ghcr.io/tailscale/tailscale:v1.90.9";
    volumes = [ "blocky-ts-state:/var/lib/tailscale" ];
    environment = {
      TS_HOSTNAME = tsHostname;
      TS_STATE_DIR = "/var/lib/tailscale";
      # --accept-dns=false: this node *is* the resolver. Accepting the tailnet's
      # DNS config would point blocky's own upstream lookups back at itself once
      # it is set as the tailnet nameserver.
      #
      # No --advertise-tags needed: the key already carries tag:claw, so the node
      # lands tagged on its own. Advertising a tag the key does *not* carry is
      # rejected outright ("requested tags [...] are invalid or not permitted"),
      # which is what the devenv key would do here.
      TS_EXTRA_ARGS = "--accept-dns=false";
    };
    environmentFiles = [ config.sops.templates."blocky-ts.env".path ];
    extraOptions = [
      # Kernel (TUN) mode rather than userspace networking: userspace only
      # proxies TCP, which is the whole reason for this sidecar.
      "--device=/dev/net/tun:/dev/net/tun:rwm"
      "--cap-add=NET_ADMIN"
      "--cap-add=NET_RAW"
      # Resolve tailscale's own control plane without depending on blocky.
      "--dns=1.1.1.1"
      "--health-cmd=tailscale status --peers=false"
      "--health-interval=30s"
      "--health-timeout=5s"
      "--health-start-period=30s"
    ];
  };

  virtualisation.oci-containers.containers.blocky = {
    image = "ghcr.io/0xerr0r/blocky:v0.34.0";
    volumes = [ "${blockyConfig}:/app/config.yml:ro" ];
    dependsOn = [ "blocky-ts" ];
    extraOptions = [
      # Share the sidecar's netns: blocky binds 0.0.0.0 inside it, which is the
      # tailnet interface. No host port is published.
      "--network=container:blocky-ts"
      # The image declares no HEALTHCHECK of its own (podman reports null), so
      # without this a wedged resolver would still show as "Up". JSON-array form
      # is required: a bare string is wrapped in CMD-SHELL, and this image is
      # distroless -- no /bin/sh, so the probe would exit 1 with empty output.
      ''--health-cmd=["/app/blocky","healthcheck"]''
      "--health-interval=30s"
      "--health-timeout=5s"
      "--health-start-period=30s"
    ];
  };

  # --network=container: binds blocky to the sidecar's netns for the lifetime of
  # that container; if the sidecar restarts the namespace is gone and blocky has
  # to follow it.
  systemd.services."podman-blocky" = {
    after = [ "podman-blocky-ts.service" ];
    requires = [ "podman-blocky-ts.service" ];
    partOf = [ "podman-blocky-ts.service" ];
  };
}
