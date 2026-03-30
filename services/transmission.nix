{ pkgs, ... }:
let
  videoExts = [ "mp4" "mkv" "avi" "mov" "wmv" "m4v" "ts" "webm" "flv" "mpg" "mpeg" "divx" "vob" ];

  doneScript = pkgs.writeShellScript "transmission-torrent-done" ''
    set -euo pipefail

    is_video() {
      local ext="''${1##*.}"
      local lower
      lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
      for e in ${builtins.concatStringsSep " " videoExts}; do
        [ "$lower" = "$e" ] && return 0
      done
      return 1
    }

    upload_file() {
      local file="$1"
      ${pkgs.rclone}/bin/rclone copy \
        --config /run/secrets/rclone_config \
        "$file" \
        "SB1-sub1:data/"
    }

    torrent_path="$TR_TORRENT_DIR/$TR_TORRENT_NAME"

    if [ -f "$torrent_path" ]; then
      if is_video "$torrent_path"; then
        upload_file "$torrent_path"
      fi
    elif [ -d "$torrent_path" ]; then
      find "$torrent_path" -type f | while IFS= read -r file; do
        if is_video "$file"; then
          upload_file "$file"
        fi
      done
    fi
  '';
in
{
  services.transmission = {
    enable = true;
    package = pkgs.transmission_4;
    openRPCPort = true;
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
      encryption = 2;
      "script-torrent-done-enabled" = true;
      "script-torrent-done-filename" = "${doneScript}";
    };
  };

}
