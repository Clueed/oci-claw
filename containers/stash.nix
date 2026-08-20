{
  pkgs,
  lib,
  config,
  ...
}:

let
  cfg = config.local.stash;

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
      --rc-addr :${toString cfg.vfsRcPort} \
      --rc-no-auth
  '';

  # Backup notes, learned the hard way (2026-08-20):
  #
  # `sqlite3 .backup` exits 0 on a corrupt database and copies the corruption
  # faithfully. Its exit code only catches I/O errors, so it is NOT a
  # corruption check. The previous version of this script trusted it, pushed a
  # malformed DB to the single remote copy every 5 minutes (~9130 times) and
  # destroyed the only good backup in the process. Hence, below:
  #   - every snapshot is validated with PRAGMA integrity_check before it is
  #     allowed anywhere near the remote,
  #   - good snapshots are kept as timestamped generations, so one bad push
  #     can never be the end of the history,
  #   - change detection uses sha256, not rclone's size-only fallback
  #     ("No common hash found" on this webdav remote),
  #   - the -wal/-shm sidecars are never synced; a stale WAL landing next to a
  #     restored DB is itself a corruption vector,
  #   - a restore verifies before installing, and walks back through the
  #     generations until one passes,
  #   - failure is loud: it marks the container unhealthy instead of scrolling
  #     past in the journal.
  rcloneSyncScript = ''
    apk add --no-cache sqlite

    REMOTE="SB1-sub1:stash-config"
    LOCAL="/config"
    RCLONE="rclone --config /rclone-conf/rclone.conf"
    DB="$LOCAL/stash-go.sqlite"
    HIST="$REMOTE/db-history"
    WORK=/tmp/dbbackup
    STAMP="$LOCAL/.last-good-backup"
    GENSTAMP="$LOCAL/.last-generation"
    ALARM="$LOCAL/.backup-alarm"
    # Stash touches the DB (view dates, o-counts) most cycles, so a
    # count-based history would be measured in minutes. Generations are
    # therefore rate-limited to one per GEN_INTERVAL, giving KEEP days of
    # history, while the canonical copy is refreshed every cycle.
    KEEP=14
    GEN_INTERVAL=86400
    STALE_AFTER=86400

    # The DB is pushed only via the verified path below, and the sidecars must
    # never travel. Patterns without a slash match the basename at any depth.
    DBEX="--exclude stash-go.sqlite --exclude stash-go.sqlite-wal --exclude stash-go.sqlite-shm --exclude stash-go.sqlite-journal --exclude db-history/**"

    mkdir -p "$WORK"

    # Verify a candidate DB file. Prints "ok" on success.
    verify_db() {
      if [ ! -s "$1" ]; then
        echo "empty-or-missing"
        return 1
      fi
      chk=$(sqlite3 "$1" "PRAGMA integrity_check;" 2>&1 | head -1)
      if [ "$chk" != "ok" ]; then
        echo "$chk"
        return 1
      fi
      # A DB that passes integrity_check but has no schema is not a stash DB.
      if ! sqlite3 "$1" "SELECT 1 FROM schema_migrations LIMIT 1;" >/dev/null 2>&1; then
        echo "no-schema_migrations"
        return 1
      fi
      echo ok
    }

    raise_alarm() {
      printf '%s\n' "$1" > "$ALARM"
      echo "ALARM: $1"
    }

    rm -f /config/.ready

    until ls /data/remote/. >/dev/null 2>&1; do sleep 1; done

    echo "Pulling config from remote..."
    $RCLONE copy --update "$REMOTE/" "$LOCAL/" $DBEX 2>/dev/null || true

    # Only restore when there is no local DB. The live local DB is
    # authoritative while stash runs; pulling a "newer" remote over it is how
    # a bad remote copy would clobber a good local one.
    if [ -f "$DB" ]; then
      echo "Local database present, leaving it alone."
    else
      echo "No local database. Attempting verified restore from remote..."
      restored=""
      # Newest generation first, then the canonical copy as a last resort.
      CANDIDATES=$( ($RCLONE lsf "$HIST" --include "stash-go.sqlite.*" 2>/dev/null \
                       | grep -v '\.sha256$' | sort -r | sed "s|^|db-history/|"; \
                     echo "stash-go.sqlite") )
      for cand in $CANDIDATES; do
        rm -f "$WORK/pull.sqlite"
        $RCLONE copyto "$REMOTE/$cand" "$WORK/pull.sqlite" 2>/dev/null || continue
        res=$(verify_db "$WORK/pull.sqlite")
        if [ "$res" = "ok" ]; then
          mv "$WORK/pull.sqlite" "$DB"
          echo "Restored verified database from $cand"
          restored=1
          break
        fi
        echo "Rejected $cand (integrity: $res)"
      done
      rm -f "$WORK/pull.sqlite"
      if [ -z "$restored" ]; then
        echo "No verified database available on remote; stash will create a new one."
      fi
    fi

    echo "Initial pull complete."

    touch /config/.ready
    echo "Ready signal sent."

    while true; do
      sleep 300

      echo "Syncing..."

      $RCLONE copy --update "$REMOTE/" "$LOCAL/" $DBEX

      if ! $RCLONE check "$LOCAL/" "$REMOTE/" $DBEX 2>/dev/null; then
        $RCLONE copy --update "$LOCAL/" "$REMOTE/" $DBEX
        echo "Config synced (changed)"
      fi

      if [ -f "$DB" ]; then
        rm -f "$WORK/db.sqlite"
        if sqlite3 "$DB" ".backup '$WORK/db.sqlite'" 2>/dev/null; then
          result=$(verify_db "$WORK/db.sqlite")
          if [ "$result" = "ok" ]; then
            # sha256, because this remote exposes no common hash and rclone
            # would otherwise fall back to comparing size alone.
            sum=$(sha256sum "$WORK/db.sqlite" | cut -d' ' -f1)
            prev=$(cut -d' ' -f1 "$STAMP" 2>/dev/null)
            if [ "$sum" != "$prev" ]; then
              now=$(date -u +%s)
              # --ignore-times is load-bearing. This webdav remote exposes no
              # hashes and no usable modtimes, so rclone falls back to
              # size-only and SILENTLY SKIPS a same-size upload. A SQLite file
              # keeps its size across many writes, which is how the previous
              # version logged ~9130 successful backups while the remote copy
              # stayed frozen for 18 days.
              if $RCLONE copyto --ignore-times "$WORK/db.sqlite" "$REMOTE/stash-go.sqlite"; then
                printf '%s %s %s\n' "$sum" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$now" > "$STAMP"
                echo "Database backed up and verified"
                rm -f "$ALARM"

                # Roll a retained generation at most once per GEN_INTERVAL.
                genlast=$(cut -d' ' -f1 "$GENSTAMP" 2>/dev/null)
                case "$genlast" in
                  ""|*[!0-9]*) genlast=0 ;;
                esac
                if [ $((now - genlast)) -ge "$GEN_INTERVAL" ]; then
                  ts=$(date -u +%Y%m%dT%H%M%SZ)
                  if $RCLONE copyto --ignore-times "$WORK/db.sqlite" "$HIST/stash-go.sqlite.$ts" \
                     && printf '%s  stash-go.sqlite.%s\n' "$sum" "$ts" \
                          | $RCLONE rcat "$HIST/stash-go.sqlite.$ts.sha256"; then
                    printf '%s %s\n' "$now" "$ts" > "$GENSTAMP"
                    echo "Retained generation $ts"

                    # End-to-end proof that the remote really holds these
                    # bytes, not just a same-size file rclone declined to
                    # replace. Once per generation, so the egress is trivial.
                    rm -f "$WORK/verify.sqlite"
                    if $RCLONE copyto "$HIST/stash-go.sqlite.$ts" "$WORK/verify.sqlite" 2>/dev/null; then
                      back=$(sha256sum "$WORK/verify.sqlite" | cut -d' ' -f1)
                      if [ "$back" = "$sum" ]; then
                        echo "Round-trip verified generation $ts"
                      else
                        raise_alarm "generation $ts read back with wrong sha256 (expected $sum, got $back)"
                      fi
                    else
                      echo "WARN: could not read back generation $ts for verification"
                    fi
                    rm -f "$WORK/verify.sqlite"

                    # Prune oldest generations beyond KEEP.
                    gens=$($RCLONE lsf "$HIST" --include "stash-go.sqlite.*" 2>/dev/null \
                             | grep -v '\.sha256$' | sort)
                    total=$(printf '%s\n' "$gens" | grep -c . )
                    drop=$((total - KEEP))
                    if [ "$drop" -gt 0 ]; then
                      printf '%s\n' "$gens" | head -n "$drop" | while read -r old; do
                        [ -n "$old" ] || continue
                        $RCLONE deletefile "$HIST/$old" 2>/dev/null || true
                        $RCLONE deletefile "$HIST/$old.sha256" 2>/dev/null || true
                        echo "Pruned old generation $old"
                      done
                    fi
                  else
                    echo "WARN: generation snapshot failed; canonical copy is current"
                  fi
                fi
              else
                echo "WARN: push failed (network/remote), keeping last good backup; will retry"
              fi
            else
              echo "Database unchanged since last verified backup"
              rm -f "$ALARM"
            fi
          else
            # Do not push. The last good remote generation stays intact.
            raise_alarm "database integrity check FAILED ($result) at $(date -u +%Y-%m-%dT%H:%M:%SZ) - refusing to push, remote history preserved"
          fi
        else
          raise_alarm "sqlite3 .backup could not read the database at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        fi
        rm -f "$WORK/db.sqlite"

        # Surface a backup that has silently stopped succeeding.
        if [ -f "$STAMP" ]; then
          last=$(cut -d' ' -f3 "$STAMP")
          now=$(date -u +%s)
          case "$last" in
            ""|*[!0-9]*) last=0 ;;
          esac
          if [ "$last" -gt 0 ] && [ $((now - last)) -gt "$STALE_AFTER" ]; then
            raise_alarm "no verified backup in $(( (now - last) / 3600 ))h (last $(cut -d' ' -f2 "$STAMP"))"
          fi
        fi
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
    # rclone's rc, on loopback. The transmission torrent-done hook calls
    # vfs/refresh through it: it uploads straight to the remote, so this
    # mount's directory cache has to be dropped before stash scans.
    ports = [ "127.0.0.1:${toString cfg.vfsRcPort}:${toString cfg.vfsRcPort}" ];
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
      # Unhealthy when the DB backup is failing or has gone stale, so it shows
      # up in `podman ps` instead of only in the journal.
      "--health-cmd=test -f /config/.ready && ! test -f /config/.backup-alarm"
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
      STASH_PORT = toString cfg.port;
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
    ports = [ "127.0.0.1:${toString cfg.port}:${toString cfg.port}" ];
    extraOptions = [
      "--security-opt=apparmor:unconfined"
      "--health-cmd=wget -q --spider http://localhost:${toString cfg.port}/"
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

  # local.stash.port is exposed via Tailscale Services (svc:stash)
}
