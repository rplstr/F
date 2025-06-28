{
  description = "F";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, zig }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          zig.packages.${system}."0.14.0"
          pkgs.xorg.libX11
          pkgs.wayland
          pkgs.wayland-scanner
          pkgs.wayland-protocols
          pkgs.pkg-config
        ];

        shellHook = ''
          export WAYLAND_PROTOCOLS_DIR=${pkgs.wayland-protocols}/share/wayland-protocols
          echo "WAYLAND_PROTOCOLS_DIR set to $WAYLAND_PROTOCOLS_DIR"
        '';
      };
    };
} 