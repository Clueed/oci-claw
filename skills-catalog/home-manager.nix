{ agent-toolkit, local-skills, ... }:

{
  programs.agent-skills = {
    sources.local = {
      path = local-skills;
      subdir = "";
      filter.maxDepth = 1;
    };
    sources.toolkit = {
      path = agent-toolkit;
      subdir = "skills";
      filter.maxDepth = 1;
    };
    skills.enableAll = true;
    targets.agents.enable = true;
  };
}
