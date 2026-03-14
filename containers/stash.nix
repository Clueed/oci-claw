{
  pkgs,
  lib,
  config,
  ...
}:

let
  rcloneMountScript = ''
    apk add --no-cache fuse
    fusermount -uz /data/remote || umount -l /data/remote || true
    mkdir -p /data/remote
    exec rclone mount --config /rclone-conf/rclone.conf SB1-sub1:data /data/remote \
      --allow-other \
      --allow-non-empty \
      --vfs-cache-mode full \
      --vfs-read-chunk-size 64M \
      --vfs-read-chunk-size-limit off \
      --buffer-size 1024M \
      --transfers 8 \
      --dir-cache-time 5m \
      --rc \
      --rc-addr :5572 \
      --rc-no-auth
  '';

  rcloneSyncScript = ''
    apk add --no-cache sqlite

    REMOTE="SB1-sub1:stash-config"
    LOCAL="/config"
    RCLONE="rclone --config /rclone-conf/rclone.conf"

    rm -f /config/.ready

    until ls /data/remote/. 2>/dev/null; do sleep 1; done

    echo "Pulling config from remote..."
    $RCLONE copy --update "$REMOTE/scrapers/" "$LOCAL/scrapers/" 2>/dev/null || mkdir -p "$LOCAL/scrapers"
    $RCLONE copy --update "$REMOTE/plugins/" "$LOCAL/plugins/" 2>/dev/null || mkdir -p "$LOCAL/plugins"
    $RCLONE copy --update "$REMOTE/config.yml" "$LOCAL/" 2>/dev/null || true

    echo "Pulling database from remote (if newer)..."
    $RCLONE copy --update "$REMOTE/" "$LOCAL/" --include "stash-go.sqlite" 2>/dev/null || echo "No remote DB, will create new"

    echo "Initial pull complete."

    touch /config/.ready
    echo "Ready signal sent."

    while true; do
      sleep 300

      echo "Syncing..."

      $RCLONE copy --update "$REMOTE/scrapers/" "$LOCAL/scrapers/"
      $RCLONE copy --update "$REMOTE/plugins/" "$LOCAL/plugins/"
      $RCLONE copy --update "$REMOTE/config.yml" "$LOCAL/"

      $RCLONE copy --update "$LOCAL/scrapers/" "$REMOTE/scrapers/"
      $RCLONE copy --update "$LOCAL/plugins/" "$REMOTE/plugins/"
      $RCLONE copy --update "$LOCAL/config.yml" "$REMOTE/"

      if [ -f "$LOCAL/stash-go.sqlite" ]; then
        sqlite3 "$LOCAL/stash-go.sqlite" ".backup '/tmp/stash-go.sqlite'"
        $RCLONE copyto "/tmp/stash-go.sqlite" "$REMOTE/stash-go.sqlite"
        rm -f /tmp/stash-go.sqlite
        echo "Database backed up"
      fi

      echo "Sync complete"
    done
  '';

  stashEntrypointScript = ''
    echo "Waiting for config sync to complete..."
    until [ -f /root/.stash/.ready ]; do sleep 1; done
    echo "Config ready, starting stash."
    exec /usr/bin/stash
  '';
in
{
  sops.secrets.rclone_config = { };

  systemd.tmpfiles.rules = [
    "d /mnt/stash-data 0755 root root -"
  ];

  virtualisation.podman = {
    enable = true;
    autoPrune.enable = true;
    dockerCompat = true;
  };

  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers.rclone-mount = {
    image = "docker.io/rclone/rclone:latest";
    volumes = [
      "${config.sops.secrets.rclone_config.path}:/rclone-conf/rclone.conf:ro"
      "/mnt/stash-data:/data:shared"
    ];
    extraOptions = [
      "--cap-add=SYS_ADMIN"
      "--device=/dev/fuse:/dev/fuse:rwm"
      "--security-opt=apparmor:unconfined"
      "--health-cmd=ls /data/remote/. 2>/dev/null"
      "--health-interval=10s"
      "--health-timeout=5s"
      "--entrypoint=[\"sh\",\"-c\",${builtins.toJSON rcloneMountScript}]"
    ];
  };

  virtualisation.oci-containers.containers.rclone-sync = {
    image = "docker.io/rclone/rclone:latest";
    volumes = [
      "${config.sops.secrets.rclone_config.path}:/rclone-conf/rclone.conf:ro"
      "stash-config:/config"
      "/mnt/stash-data:/data:slave"
    ];
    extraOptions = [
      "--health-cmd=test -f /config/.ready"
      "--health-interval=30s"
      "--health-timeout=5s"
      "--entrypoint=[\"sh\",\"-c\",${builtins.toJSON rcloneSyncScript}]"
    ];
  };

  virtualisation.oci-containers.containers.stash = {
    image = "docker.io/stashapp/stash:v0.30.1";
    environment = {
      STASH_STASH = "/data";
      STASH_GENERATED = "/generated/";
      STASH_METADATA = "/metadata/";
      STASH_CACHE = "/cache/";
      STASH_PORT = "9999";
    };
    volumes = [
      "stash-config:/root/.stash"
      "stash-generated:/generated"
      "stash-cache:/cache"
      "stash-metadata:/metadata"
      "stash-blobs:/blobs"
      "stash-local:/data/local"
      "/mnt/stash-data:/data:slave"
    ];
    ports = [ "9999:9999" ];
    extraOptions = [
      "--security-opt=apparmor:unconfined"
      "--health-cmd=wget -q --spider http://localhost:9999/"
      "--health-interval=30s"
      "--health-timeout=10s"
      "--health-retries=3"
      "--health-start-period=40s"
      "--entrypoint=[\"sh\",\"-c\",${builtins.toJSON stashEntrypointScript}]"
    ];
  };

  systemd.services."podman-rclone-sync" = {
    after = [ "podman-rclone-mount.service" ];
    requires = [ "podman-rclone-mount.service" ];
  };

  systemd.services."podman-stash" = {
    after = [ "podman-rclone-sync.service" ];
    requires = [ "podman-rclone-sync.service" ];
  };

  networking.firewall.allowedTCPPorts = [ 9999 ];
}
