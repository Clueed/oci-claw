{
  description = "Dev environment: @NAME@";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    opencode.url = "github:sst/opencode";
    anthropic-skills = {
      url = "github:anthropics/skills";
      flake = false;
    };
    vercel-agent-browser = {
      url = "github:vercel-labs/agent-browser";
      flake = false;
    };
  };

  outputs =
    {
      nixpkgs,
      opencode,
      anthropic-skills,
      vercel-agent-browser,
      ...
    }:
    {
      nixosConfigurations."container" = nixpkgs.lib.nixosSystem {
        system = "@SYSTEM@";
        specialArgs = {
          inherit opencode anthropic-skills vercel-agent-browser;
          projectName = "@NAME@";
        };
        modules = [ ./container.nix ];
      };
    };
}
