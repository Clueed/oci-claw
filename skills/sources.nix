{ ... }:
{
  programs.agent-skills = {
    enable = true;
    sources.local = {
      path = ./.;
      subdir = ".";
    };
    targets.agents.enable = true;
    targets.claude.enable = true;
  };
}
