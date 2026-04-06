{
  description = "Dev environment: @NAME@";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    opencode.url = "github:sst/opencode";
    vscode-server.url = "github:nix-community/nixos-vscode-server";
    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      opencode,
      vscode-server,
      home-manager,
      ...
    }:
    {
      nixosConfigurations."container" = nixpkgs.lib.nixosSystem {
        system = "@SYSTEM@";
        specialArgs = {
          inherit opencode;
          projectName = "@NAME@";
        };
        modules = [
          vscode-server.nixosModules.default
          home-manager.nixosModules.home-manager
          { home-manager.useGlobalPkgs = true; }
          ./container.nix
          {
            home-manager.users.dev.imports = [ vscode-server.homeModules.default ];
          }
        ];
      };
    };
}
