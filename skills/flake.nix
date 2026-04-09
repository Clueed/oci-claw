{
  description = "skills catalog flake";

  inputs = {
    agent-skills.url = "github:Kyure-A/agent-skills-nix";
  };

  outputs =
    { self, agent-skills, ... }:
    {
      homeManagerModules.default = {
        imports = [
          agent-skills.homeManagerModules.default
          ./home-manager.nix
        ];
      };
    };
}
