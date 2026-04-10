{ ... }:
{
  imports = [ ./sources.nix ];
  programs.agent-skills.skills.enable = [ "opencode-history" ];
}
