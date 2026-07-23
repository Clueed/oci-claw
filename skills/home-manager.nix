{ ... }:
{
  imports = [ ./sources.nix ];
  programs.agent-skills.skills.enable = [
    "opencode-history"
    "commit-work"
    "devenv"
    "skill-creator"
    "download-video"
    "create-video-subtitles"
    "agent-browser"
    "stash"
    "torrent-server"
  ];
}
