{
  description = "skills catalog flake";

  inputs = {
    agent-skills.url = "github:Kyure-A/agent-skills-nix";
    softaworks-toolkit = {
      url = "github:softaworks/agent-toolkit";
      flake = false;
    };
  };

  outputs =
    { self, agent-skills, ... }:
    {
      # Sources only — registers the agent-skills option and declares sources/targets.
      # Consumers set their own skills.enable.
      homeManagerModules.sources = {
        imports = [
          agent-skills.homeManagerModules.default
          ./sources.nix
        ];
      };

      # Full host config — sources + host skill selection.
      homeManagerModules.default = {
        imports = [
          agent-skills.homeManagerModules.default
          ./home-manager.nix
        ];
      };
    };
}
