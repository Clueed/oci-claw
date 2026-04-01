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
      --vfs-cache-max-size 80G \
      --vfs-cache-max-age 1h \
      --vfs-cache-poll-interval 1m \
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

    until ls /data/remote/. >/dev/null 2>&1; do sleep 1; done

    echo "Pulling config from remote..."
    $RCLONE copy --update "$REMOTE/" "$LOCAL/" --exclude "stash-go.sqlite" 2>/dev/null || true

    echo "Pulling database from remote (if newer)..."
    $RCLONE copy --update "$REMOTE/" "$LOCAL/" --include "stash-go.sqlite" 2>/dev/null || echo "No remote DB, will create new"

    echo "Initial pull complete."

    touch /config/.ready
    echo "Ready signal sent."

    while true; do
      sleep 300

      echo "Syncing..."

      $RCLONE copy --update "$REMOTE/" "$LOCAL/" --exclude "stash-go.sqlite"

      if ! $RCLONE check "$LOCAL/" "$REMOTE/" --exclude "stash-go.sqlite" 2>/dev/null; then
        $RCLONE copy --update "$LOCAL/" "$REMOTE/" --exclude "stash-go.sqlite"
        echo "Config synced (changed)"
      fi

      if [ -f "$LOCAL/stash-go.sqlite" ]; then
        if sqlite3 "$LOCAL/stash-go.sqlite" ".backup '/tmp/stash-go.sqlite'" 2>/dev/null; then
          if ! $RCLONE check "/tmp/stash-go.sqlite" "$REMOTE/stash-go.sqlite" 2>/dev/null; then
            $RCLONE copyto "/tmp/stash-go.sqlite" "$REMOTE/stash-go.sqlite"
            echo "Database backed up (changed)"
          fi
        else
          echo "ERROR: Database backup failed (possible corruption), skipping remote push"
        fi
        rm -f /tmp/stash-go.sqlite
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
  sops.secrets.rclone_config = {
    group = "transmission";
    mode = "0440";
  };

  systemd.tmpfiles.rules = [
    "d /mnt/stash-data 0755 root root -"
  ];

  virtualisation.podman = {
    enable = true;
    autoPrune.enable = true;
    dockerCompat = true;
  };

  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers.stash-data-mount = {
    image = "docker.io/rclone/rclone:latest";
    volumes = [
      "${config.sops.secrets.rclone_config.path}:/rclone-conf/rclone.conf:ro"
      "/mnt/stash-data:/data:shared"
    ];
    extraOptions = [
      "--cap-add=SYS_ADMIN"
      "--device=/dev/fuse:/dev/fuse:rwm"
      "--security-opt=apparmor:unconfined"
      "--dns=1.1.1.1"
      "--health-cmd=ls /data/remote/. 2>/dev/null"
      "--health-interval=10s"
      "--health-timeout=5s"
      "--entrypoint=[\"sh\",\"-c\",${builtins.toJSON rcloneMountScript}]"
    ];
  };

  virtualisation.oci-containers.containers.stash-config-sync = {
    image = "docker.io/rclone/rclone:latest";
    volumes = [
      "${config.sops.secrets.rclone_config.path}:/rclone-conf/rclone.conf:ro"
      "stash-config:/config"
      "/mnt/stash-data:/data:slave"
    ];
    extraOptions = [
      "--dns=1.1.1.1"
      "--health-cmd=test -f /config/.ready"
      "--health-interval=30s"
      "--health-timeout=5s"
      "--entrypoint=[\"sh\",\"-c\",${builtins.toJSON rcloneSyncScript}]"
    ];
  };

  virtualisation.oci-containers.containers.stash-app = {
    image = "docker.io/stashapp/stash:v0.31.0";
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
    ports = [ "127.0.0.1:9999:9999" ];
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

  systemd.services."podman-stash-config-sync" = {
    after = [ "podman-stash-data-mount.service" ];
    requires = [ "podman-stash-data-mount.service" ];
  };

  systemd.services."podman-stash-app" = {
    after = [ "podman-stash-config-sync.service" ];
    requires = [ "podman-stash-config-sync.service" ];
  };

  # Port 9999 is exposed via Tailscale Services (svc:stash)
}
