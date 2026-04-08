{ agent-toolkit, local-skills, ... }:

{
  programs.agent-skills = {
    enable = true;
    sources.local = {
      path = local-skills;
      subdir = "";
      filter.maxDepth = 1;
    };
    sources.toolkit = {
      path = agent-toolkit;
      subdir = "skills";
      idPrefix = "toolkit";
      filter.maxDepth = 1;
    };
    skills.enable = [
      "devenvs"
      "opencode-history"
      "toolkit/commit-work"
    ];
    targets.agents.enable = true;
  };
}
