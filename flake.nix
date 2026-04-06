{
  description = "NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    opencode.url = "github:sst/opencode";
    vscode-server.url = "github:nix-community/nixos-vscode-server";
    vscode-server.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      sops-nix,
      opencode,
      vscode-server, # pinned for devenv containers; not used by host
      ...
    }:
    let
      pkgs = nixpkgs.legacyPackages.aarch64-linux;
    in
    {
      formatter.aarch64-linux = pkgs.nixfmt-tree;

      nixosConfigurations."ociclaw-1" = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit opencode; };
        modules = [
          ./configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
          {
            environment.systemPackages = [
              opencode.packages.aarch64-linux.default
              pkgs.gh
              pkgs.git
              pkgs.sops
            ];
          }
        ];
      };
    };
}
