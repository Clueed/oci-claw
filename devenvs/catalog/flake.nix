{
  description = "Devenvs catalog: reusable devenv container configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    opencode.url = "github:sst/opencode";
    vscode-server.url = "github:nix-community/nixos-vscode-server";
    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    agent-skills.url = "github:Kyure-A/agent-skills-nix";
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
    inputs@{
      self,
      nixpkgs,
      opencode,
      vscode-server,
      home-manager,
      agent-skills,
      anthropic-skills,
      vercel-agent-browser,
      ...
    }:
    let
      systems = {
        x86_64 = "x86_64-linux";
        aarch64 = "aarch64-linux";
        arm64 = "aarch64-linux";
      };
      mkContainer =
        system: name: projectMountPath:
        nixpkgs.lib.nixosSystem {
          system = systems.${system};
          specialArgs = {
            inherit opencode;
            projectName = name;
            projectMountPath = projectMountPath;
            inherit agent-skills anthropic-skills vercel-agent-browser;
          };
          modules = [
            vscode-server.nixosModules.default
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.extraSpecialArgs = {
                inherit inputs;
              };
            }
            ./container.nix
            {
              home-manager.users.dev.imports = [
                vscode-server.homeModules.default
                agent-skills.homeManagerModules.default
              ];
            }
          ];
        };
    in
    {
      containers.x86_64 = name: projectMountPath: mkContainer "x86_64" name projectMountPath;
      containers.aarch64 = name: projectMountPath: mkContainer "aarch64" name projectMountPath;
    };
}
