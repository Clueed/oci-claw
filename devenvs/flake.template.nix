{
  description = "Dev environment: @NAME@";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    opencode.url = "github:sst/opencode";
    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      opencode,
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
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
          }
          ./container.nix
        ];
      };
    };
}
