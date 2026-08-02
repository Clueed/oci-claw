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

    upload_file() {
      local file="$1"
      ${pkgs.rclone}/bin/rclone copy \
        --config /run/secrets/rclone_config \
        "$file" \
        "SB1-sub1:data/"
    }

    # Videos only. Images from auto-imported torrents are previews, browsed
    # locally through the image gallery -- they must not reach the stash dir.
    should_upload() { is_video "$1"; }

    log() { echo "torrent-done[''${TR_TORRENT_NAME:-?}]: $*"; }

    torrent_path="$TR_TORRENT_DIR/$TR_TORRENT_NAME"

    uploaded=0

    if [ -f "$torrent_path" ]; then
      if should_upload "$torrent_path"; then
        upload_file "$torrent_path"
        uploaded=1
      fi
    elif [ -d "$torrent_path" ]; then
      # Read from a process substitution, not a pipe: a pipeline would run the
      # loop in a subshell and lose the uploaded flag.
      while IFS= read -r file; do
        if should_upload "$file"; then
          upload_file "$file"
          uploaded=1
        fi
      done < <(find "$torrent_path" -type f)
    fi

    if [ "$uploaded" -eq 0 ]; then
      log "nothing uploaded, no scan"
      exit 0
    fi

    # rclone copied straight to the remote, so the VFS mount stash reads its
    # library through still has the old directory listing cached
    # (--dir-cache-time 5m). Drop it first or the scan finds nothing new.
    # An empty body refreshes the root, which is where uploads land; passing
    # dir="/" is rejected as a nonexistent path.
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
      log "uploaded, triggered stash scan (job $job)"
    else
      log "uploaded, but stash scan failed: ''${scan:-no response}"
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
