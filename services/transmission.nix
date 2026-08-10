{ pkgs, config, ... }:
let
  watchDir = "/home/claw/projects/torrents";
  rpcUrl = "http://127.0.0.1:9091/transmission/rpc";

  # Stash's GraphQL API, and the rclone rc of the VFS mount that backs stash's
  # library (see containers/stash.nix). Both loopback-only, no auth.
  stashUrl = config.local.stash.url;
  vfsRcUrl = config.local.stash.vfsRcUrl;

  videoExts = [
    "mp4"
    "mkv"
    "avi"
    "mov"
    "wmv"
    "m4v"
    "ts"
    "webm"
    "flv"
    "mpg"
    "mpeg"
    "divx"
    "vob"
  ];

  imageExts = [
    "jpg"
    "jpeg"
    "png"
    "gif"
    "webp"
    "bmp"
    "tif"
    "tiff"
    "heic"
    "heif"
    "avif"
  ];

  # Case-insensitive "ends with one of these extensions" regex, for jq's test().
  # Applied to an already-lowercased string.
  imageRegex = "\\.(${builtins.concatStringsSep "|" imageExts})$";

  # rclone filters restricting a directory copy to video files. Paired with
  # --ignore-case so .MKV matches .mkv too.
  videoFilters = builtins.concatStringsSep " " (map (e: "--include '*.${e}'") videoExts);

  # Shared shell prelude: ext matching + an unauthenticated RPC helper.
  # RPC needs no credentials (rpc-authentication-required = false) and is
  # bound to loopback only.
  common = ''
    matches_ext() {
      local file="$1"
      shift
      local lower
      lower=$(echo "''${file##*.}" | tr '[:upper:]' '[:lower:]')
      for e in "$@"; do
        [ "$lower" = "$e" ] && return 0
      done
      return 1
    }

    is_video() { matches_ext "$1" ${builtins.concatStringsSep " " videoExts}; }

    rpc() {
      local sid
      sid=$(${pkgs.curl}/bin/curl -s -D - -o /dev/null ${rpcUrl} \
        | ${pkgs.gnugrep}/bin/grep -i '^X-Transmission-Session-Id:' \
        | tr -d '\r' | ${pkgs.gawk}/bin/awk '{print $2}')
      ${pkgs.curl}/bin/curl -s \
        -H "X-Transmission-Session-Id: $sid" \
        -H "Content-Type: application/json" \
        --data-binary "$1" \
        ${rpcUrl}
    }
  '';

  # Fires for every torrent added, from any source. We only want to touch the
  # ones auto-imported from the watch dir, and Transmission doesn't tell us
  # where a torrent came from -- so match TR_TORRENT_HASH against the hashes of
  # the .torrent files still sitting in the watch dir (they are kept there,
  # trash-original-torrent-files = false).
  addedScript = pkgs.writeShellScript "transmission-torrent-added" ''
    set -euo pipefail

    ${common}

    log() { echo "torrent-added[''${TR_TORRENT_NAME:-?}]: $*"; }

    from_watch_dir() {
      local hash
      hash=$(echo "$TR_TORRENT_HASH" | tr '[:upper:]' '[:lower:]')
      shopt -s nullglob
      for t in ${watchDir}/*.torrent; do
        local h
        h=$(${pkgs.transmission_4}/bin/transmission-show "$t" 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep -iE '^[[:space:]]*Hash( v1)?:' \
          | ${pkgs.gawk}/bin/awk '{print $NF}' \
          | tr '[:upper:]' '[:lower:]') || continue
        [ "$h" = "$hash" ] && return 0
      done
      return 1
    }

    if ! from_watch_dir; then
      log "not from watch dir, leaving untouched"
      exit 0
    fi

    id="$TR_TORRENT_ID"

    resp=$(rpc "{\"method\":\"torrent-get\",\"arguments\":{\"ids\":[$id],\"fields\":[\"files\"]}}")

    read_indices() {
      echo "$resp" | ${pkgs.jq}/bin/jq -c --arg re '${imageRegex}' \
        "[.arguments.torrents[0].files | to_entries[] | select((.value.name | ascii_downcase | test(\$re)) == $1) | .key]"
    }

    wanted=$(read_indices true)
    unwanted=$(read_indices false)

    if [ "$wanted" = "[]" ]; then
      log "no image files, leaving paused"
      exit 0
    fi

    n_wanted=$(echo "$wanted" | ${pkgs.jq}/bin/jq 'length')
    n_unwanted=$(echo "$unwanted" | ${pkgs.jq}/bin/jq 'length')

    rpc "{\"method\":\"torrent-set\",\"arguments\":{\"ids\":[$id],\"files-wanted\":$wanted,\"files-unwanted\":$unwanted}}" >/dev/null
    rpc "{\"method\":\"torrent-start\",\"arguments\":{\"ids\":[$id]}}" >/dev/null

    log "selected $n_wanted image(s), skipped $n_unwanted file(s), started"
  '';

  doneScript = pkgs.writeShellScript "transmission-torrent-done" ''
    set -euo pipefail

    ${common}

    # Root of stash's library on the remote (see containers/stash.nix).
    remoteDir="SB1-sub1:data"

    rc() {
      ${pkgs.rclone}/bin/rclone --config /run/secrets/rclone_config "$@"
    }

    log() { echo "torrent-done[''${TR_TORRENT_NAME:-?}]: $*"; }

    torrent_path="$TR_TORRENT_DIR/$TR_TORRENT_NAME"

    uploaded=0

    # Videos only, in both branches. Images from auto-imported torrents are
    # previews, browsed locally through the image gallery -- they must not
    # reach the stash dir.
    if [ -f "$torrent_path" ]; then
      # Single-file torrent: there is no folder to preserve, so it lands
      # directly in the library root.
      if is_video "$torrent_path"; then
        rc copy "$torrent_path" "$remoteDir/"
        uploaded=1
      fi
    elif [ -d "$torrent_path" ]; then
      # Multi-file torrent: copy the torrent's own folder, keeping whatever
      # nesting the videos sit in, instead of flattening them into the root.
      # Count first so an all-images torrent skips the copy (and the scan)
      # entirely; rclone's filters then do the actual selection.
      #
      # Read from a process substitution, not a pipe: a pipeline would run the
      # loop in a subshell and lose the counter.
      while IFS= read -r file; do
        if is_video "$file"; then
          uploaded=$((uploaded + 1))
        fi
      done < <(find "$torrent_path" -type f)

      if [ "$uploaded" -gt 0 ]; then
        # rclone creates no empty dirs, so image-only subfolders are not
        # mirrored. Trailing basename keeps the folder itself on the remote.
        rc copy --ignore-case ${videoFilters} \
          "$torrent_path" "$remoteDir/$(basename "$torrent_path")"
      fi
    fi

    if [ "$uploaded" -eq 0 ]; then
      log "nothing uploaded, no scan"
      exit 0
    fi

    # rclone copied straight to the remote, so the VFS mount stash reads its
    # library through still has the old directory listing cached
    # (--dir-cache-time 5m). Drop it first or the scan finds nothing new.
    # An empty body refreshes the root; passing dir="/" is rejected as a
    # nonexistent path. Refreshing the root is enough even for a folder upload:
    # the new directory shows up in the root listing, and it has no cached
    # listing of its own yet, so stash's scan sees the files inside.
    refresh=$(${pkgs.curl}/bin/curl -s -m 60 -X POST \
      -H "Content-Type: application/json" \
      --data '{}' \
      ${vfsRcUrl}/vfs/refresh) || refresh=""

    if [ "$(echo "$refresh" | ${pkgs.jq}/bin/jq -r '.result[""] // empty' 2>/dev/null)" != "OK" ]; then
      log "warning: VFS refresh failed (''${refresh:-no response}), scan may miss the new file(s)"
    fi

    scan=$(${pkgs.curl}/bin/curl -s -m 60 -X POST \
      -H "Content-Type: application/json" \
      --data '{"query":"mutation { metadataScan(input: {}) }"}' \
      ${stashUrl}) || scan=""

    job=$(echo "$scan" | ${pkgs.jq}/bin/jq -r '.data.metadataScan // empty' 2>/dev/null || true)

    if [ -n "$job" ]; then
      log "uploaded $uploaded video(s), triggered stash scan (job $job)"
    else
      log "uploaded $uploaded video(s), but stash scan failed: ''${scan:-no response}"
    fi
  '';
in
{
  services.transmission = {
    enable = true;
    package = pkgs.transmission_4;
    openRPCPort = false;
    openPeerPorts = true;
    settings = {
      rpc-bind-address = "127.0.0.1";
      rpc-authentication-required = false;
      rpc-whitelist-enabled = false;
      rpc-host-whitelist-enabled = false;
      download-dir = "/var/lib/transmission/Downloads";
      incomplete-dir-enabled = true;
      speed-limit-up = 300; # KB/s (~2.4 Mbps)
      speed-limit-up-enabled = true;
      peer-limit-global = 75;
      peer-limit-per-torrent = 25;
      dht-enabled = false;
      pex-enabled = false;
      lpd-enabled = false;
      peer-port-random-on-start = true;
      port-forwarding-enabled = false;
      encryption = 2;
      watch-dir-enabled = true;
      watch-dir = watchDir;
      watch-dir-force-generic = true;
      trash-original-torrent-files = false;
      start-added-torrents = false;
      "script-torrent-added-enabled" = true;
      "script-torrent-added-filename" = "${addedScript}";
      "script-torrent-done-enabled" = true;
      "script-torrent-done-filename" = "${doneScript}";
    };
  };

}
