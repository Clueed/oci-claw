{
  description = "NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    opencode.url = "github:sst/opencode";
    skills-catalog.url = "path:./skills";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      sops-nix,
      opencode,
      skills-catalog,
    }:
    let
      pkgs = nixpkgs.legacyPackages.aarch64-linux;
    in
    {
      formatter.aarch64-linux = pkgs.nixfmt-tree;

      lib.mkContainer =
        { name, extraModules ? [ ] }:
        nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = { inherit name; };
          modules = [
            home-manager.nixosModules.home-manager
            ./devenvs/container.nix
          ] ++ extraModules;
        };

      nixosConfigurations."ociclaw-1" = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit opencode skills-catalog; };
        modules = [
          ./configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
        ];
      };
    };
}
