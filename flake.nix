{
  description = "NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/870a442b820be7162455faa9716134eee0168223";
  };

  outputs = { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.aarch64-linux;
    in
    {
      nixosConfigurations."instance-20260311-0806" = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          ./configuration.nix
          { environment.systemPackages = [ pkgs.opencode pkgs.gh ]; }
        ];
      };
    };
}
