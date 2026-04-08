{
  description = "Skills catalog for ociclaw-1";

  inputs = {
    agent-skills.url = "github:Kyure-A/agent-skills-nix";
    agent-toolkit = {
      url = "github:softaworks/agent-toolkit";
      flake = false;
    };
    local-skills = {
      url = "path:/home/claw/nixos/skills";
      flake = false;
    };
  };

  outputs =
    {
      self,
      agent-skills,
      agent-toolkit,
      local-skills,
      ...
    }:
    {
      homeManagerModules.default = {
        imports = [
          agent-skills.homeManagerModules.default
          (import ./home-manager.nix { inherit agent-toolkit local-skills; })
        ];
      };
    };
}
