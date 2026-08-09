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

  # Single source of truth for the version: both the runtime image and the
  # validator below are pinned to it, so the binary checking the config is
  # always the binary that will run it.
  blockyVersion = "0.34.0";

  # nixpkgs ships blocky 0.27.0, which predates the `dnssec` section and would
  # reject this config outright, so build the matching version. 0.34 requires
  # Go >= 1.26.2 while this nixpkgs defaults to 1.25.10, hence the override.
  # Build-time only -- this never enters the system closure.
  blockyPkg = (pkgs.buildGoModule.override { go = pkgs.go_1_26; }) (finalAttrs: {
    pname = "blocky";
    version = blockyVersion;
    src = pkgs.fetchFromGitHub {
      owner = "0xERR0R";
      repo = "blocky";
      rev = "v${finalAttrs.version}";
      hash = "sha256-EgZId3EzfAUWsQo56Y5VGs2VJxj0tXiSuZNhd6/U/zc=";
    };
    doCheck = false;
    vendorHash = "sha256-BeRM5X0cuxHCud23lgy+fL6PGAlY7XOmeKTiDeToAeQ=";
    ldflags = [
      "-s"
      "-w"
      "-X github.com/0xERR0R/blocky/util.Version=${finalAttrs.version}"
    ];
  });

  blockyConfigFile = pkgs.writeText "blocky.yml" ''
    # DNS-over-TLS upstreams: without this, every query leaves the box in
    # cleartext on port 53, which rather defeats the point of running your own
    # resolver. Hostnames (not bare IPs) are used so the TLS certificate can
    # actually be verified against a name.
    #
    # That creates a chicken-and-egg problem -- resolving "one.one.one.one"
    # needs DNS -- which bootstrapDns breaks by pinning the IPs. It also serves
    # the blocklist downloads over HTTPS.
    bootstrapDns:
      - upstream: tcp-tls:one.one.one.one:853
        ips:
          - 1.1.1.1
          - 1.0.0.1

    upstreams:
      groups:
        default:
          - tcp-tls:one.one.one.one:853
          - tcp-tls:dns.quad9.net:853

    # No `dnssec: validate: true` here, deliberately. It was enabled once and
    # backed out: blocky 0.34's own validator produces false BOGUS verdicts. On
    # an *insecure* (unsigned) delegation it logs "Unauthenticated NSEC/NSEC3 in
    # DS response ... ignoring as DS denial", concludes the parent zone is
    # secure, and then rejects the legitimately unsigned answer with "No RRSIG
    # ... treating unsigned answer as bogus" -> SERVFAIL.
    #
    # Measured over ~1h of ordinary browsing: 133 warnings across 28 domains,
    # including redgifs.com (and i./media./userpic.), willhaben.at,
    # www.linkedin.com, graph.whatsapp.com and ocsp.sectigo.com -- OCSP, so it
    # can break certificate checks, not just name resolution. The failures are
    # intermittent, which surfaces as media that loads only some of the time.
    #
    # Nothing is lost by dropping it: both upstreams above (Cloudflare and
    # Quad9) are validating resolvers, they are reached over authenticated TLS,
    # and the link between blocky and them is the only hop this would have
    # covered. Revisit if upstream fixes the DS-denial handling.

    # HaGeZi Pro++ ("Sweeper") replaces StevenBlack rather than joining it: it is
    # a superset covering ads, affiliate, tracking, telemetry, phishing, malware,
    # scam, fake and cryptojacking, so running both would only add a second place
    # to hunt when something is wrongly blocked.
    #
    # The wildcard-asterisk file is the format HaGeZi documents for blocky 0.23+.
    # Pro++ is their aggressive tier and is documented as possibly containing
    # false positives, which is what the referral allowlist is for -- shopping
    # and referral domains that Pro++ sweeps up and that break checkout flows.
    blocking:
      denylists:
        ads:
          - https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.plus.txt
      allowlists:
        ads:
          - https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/whitelist-referral-onlydomains.txt
          # Local false-positive fixes, on top of HaGeZi's referral allowlist.
          # A multi-line string is an inline list rather than a URL.
          - |
            # willhaben is an Austrian classifieds site, so "ad" here means
            # Anzeige (a listing), not advertising -- ad-search is the listing
            # search backend, and Pro++ sweeps it up on the name alone. It is an
            # authenticated app API (302 -> /auth), not an ad server, and with it
            # blocked search in the willhaben iOS app fails.
            #
            # Deliberately not cltr.willhaben.at, which Pro++ also blocks: that
            # one reads as a collector endpoint and blocking it costs nothing.
            ad-search.willhaben.at
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

  # Schema-driven validation at build time: a typo'd key or malformed YAML fails
  # `nh os build` instead of crash-looping the container after activation.
  # blocky exits 1 on an invalid config, which fails this derivation.
  blockyConfig =
    pkgs.runCommand "blocky.yml"
      {
        nativeBuildInputs = [ blockyPkg ];
      }
      ''
        blocky validate -c ${blockyConfigFile}
        cp ${blockyConfigFile} $out
      '';
in
{
  # blocky's own key. Deliberately not tailscale_devenv_auth_key (tagged
  # tag:claw-devenv -- blocky is a service, not a dev container) and not the
  # host's tailscale_auth_key (single-use, already spent on the host's own join).
  # The key is used exactly once, to register the node; after that the identity
  # lives in the blocky-ts-state volume.
  sops.secrets.tailscale_blocky_auth_key = { };

  sops.templates."blocky-ts.env".content = ''
    TS_AUTHKEY=${config.sops.placeholder.tailscale_blocky_auth_key}
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
      # Kernel (TUN) mode. The image defaults to --tun=userspace-networking, and
      # mounting /dev/net/tun is NOT enough to change that -- this variable is.
      # Userspace/netstack does forward inbound UDP, so DNS works either way, but
      # it terminates connections and re-originates them from localhost, so every
      # client reaches blocky as 127.0.0.1. That collapses per-client blocking
      # groups, clientLookup device names, and per-client query stats.
      TS_USERSPACE = "false";
    };
    environmentFiles = [ config.sops.templates."blocky-ts.env".path ];
    extraOptions = [
      "--device=/dev/net/tun:/dev/net/tun:rwm"
      # Drop podman's default capability set and add back only what tailscaled
      # needs to build the TUN interface and its netfilter rules.
      "--cap-drop=ALL"
      "--cap-add=NET_ADMIN"
      "--cap-add=NET_RAW"
      "--security-opt=no-new-privileges"
      # Resolve tailscale's own control plane without depending on blocky.
      "--dns=1.1.1.1"
      "--health-cmd=tailscale status --peers=false"
      "--health-interval=30s"
      "--health-timeout=5s"
      "--health-start-period=30s"
    ];
  };

  virtualisation.oci-containers.containers.blocky = {
    image = "ghcr.io/0xerr0r/blocky:v${blockyVersion}";
    volumes = [ "${blockyConfig}:/app/config.yml:ro" ];
    dependsOn = [ "blocky-ts" ];
    extraOptions = [
      # Drop podman's whole default capability set. NET_BIND_SERVICE has to come
      # back: the image runs as UID 100, so binding :53 fails with
      # "listen tcp :53: bind: permission denied" without it (:4000 is fine).
      "--cap-drop=ALL"
      "--cap-add=NET_BIND_SERVICE"
      "--security-opt=no-new-privileges"
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
