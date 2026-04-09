{ ... }:

{
  programs.agent-skills = {
    enable = true;

    sources.local = {
      path = ./.;
      subdir = ".";
      filter.maxDepth = 1;
    };

    skills.enable = [ "opencode-history" ];

    targets.agents.enable = true;
  };
}
