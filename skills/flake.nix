{
  description = "skills catalog flake";

  inputs = {
    agent-skills.url = "github:Kyure-A/agent-skills-nix";
    softaworks-toolkit = {
      url = "github:softaworks/agent-toolkit";
      flake = false;
    };
    vercel-agent-browser = {
      url = "github:vercel-labs/agent-browser";
      flake = false;
    };
    shadcn-ui = {
      url = "github:shadcn-ui/ui";
      flake = false;
    };
  };

  outputs =
    {
      self,
      agent-skills,
      softaworks-toolkit,
      vercel-agent-browser,
      shadcn-ui,
      ...
    }:
    {
      # Sources only — registers the agent-skills option and declares sources/targets.
      # Consumers set their own skills.enable.
      homeManagerModules.sources = {
        imports = [
          agent-skills.homeManagerModules.default
          ./sources.nix
        ];
        config.programs.agent-skills.sources.softaworks = {
          path = softaworks-toolkit;
          subdir = "skills";
        };
        config.programs.agent-skills.sources.vercel = {
          path = vercel-agent-browser;
          subdir = "skills";
        };
        config.programs.agent-skills.sources.shadcn = {
          path = shadcn-ui;
          subdir = "skills";
        };
      };

      # Full host config — sources + host skill selection.
      homeManagerModules.default = {
        imports = [
          agent-skills.homeManagerModules.default
          ./home-manager.nix
        ];
        config.programs.agent-skills.sources.softaworks = {
          path = softaworks-toolkit;
          subdir = "skills";
        };
        config.programs.agent-skills.sources.vercel = {
          path = vercel-agent-browser;
          subdir = "skills";
        };
        config.programs.agent-skills.sources.shadcn = {
          path = shadcn-ui;
          subdir = "skills";
        };
      };
    };
}
