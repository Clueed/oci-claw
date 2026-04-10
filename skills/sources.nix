{ softaworks-toolkit, ... }:
{
  programs.agent-skills = {
    enable = true;
    sources.local = {
      path = ./.;
      subdir = ".";
      filter.maxDepth = 1;
    };
    sources.softaworks = {
      path = softaworks-toolkit;
      subdir = "skills";
    };
    targets.agents.enable = true;
    targets.claude.enable = true;
  };
}
