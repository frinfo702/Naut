{
  description = "elitedev: Markdown notes with one-click web publishing";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
  };

  outputs = inputs: {
    devShells = builtins.mapAttrs (system: _: let
      # Terraform is BSL licensed, which nixpkgs marks unfree.
      pkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg: (pkgs.lib.getName pkg) == "terraform";
      };
    in {
      # mkShellNoCC on purpose: the nix C toolchain exports SDKROOT and
      # DEVELOPER_DIR, which breaks Xcode's Swift. Swift comes from Xcode.
      default = pkgs.mkShellNoCC {
        packages = [pkgs.zig pkgs.terraform];
      };

      # Terraform is unfree, so it isn't in the binary cache and builds from
      # source (10+ minutes). CI only needs Zig; Terraform has its own job.
      ci = pkgs.mkShellNoCC {
        packages = [pkgs.zig];
      };
    }) inputs.nixpkgs.legacyPackages;
  };
}
