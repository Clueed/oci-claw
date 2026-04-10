{ ... }:
{
  programs.agent-skills = {
    enable = true;
    sources.local = {
      path = ./.;
      subdir = ".";
      filter.maxDepth = 1;
    };
    targets.agents.enable = true;
  };
}
