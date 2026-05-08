{
  description = "amon — Ansible Monitor TUI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    idris2-withpkgs.url = "github:gvnkd/flake-idris2-withPackages";
  };

  outputs = { self, nixpkgs, flake-utils, idris2-withpkgs }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        idrisLibraries = with idris2-withpkgs.packages.${system}; [
          json
          elab-util
          ansi
          tui
          tui-async
          posix
          streams
          streams-posix
        ];

        idris2Wrapped = idris2-withpkgs.lib.${system}.withPackages (p: [
          p.json
          p.elab-util
          p.ansi
          p.tui
          p.tui-async
          p.posix
          p.streams
          p.streams-posix
        ]);

        amonPkg = pkgs.idris2Packages.buildIdris {
          src = ./.;
          ipkgName = "amon";
          version = "0.1.0";
          inherit idrisLibraries;
          nativeBuildInputs = [ pkgs.gcc ];
        };

        buildScript = pkgs.writeShellScriptBin "build" ''
          set -e
          idris2 --build amon.ipkg
          echo "Build complete."
        '';
      in
      {
        packages.default = amonPkg.executable;

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            python3
            ansible
            jq
            gcc
            gnumake
            buildScript
          ];
          buildInputs = [
            idris2Wrapped
            pkgs.rlwrap
          ];

          shellHook = ''
            export LD_LIBRARY_PATH="${idris2Wrapped}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            export IDRIS2_LIBS="${idris2Wrapped}/lib''${IDRIS2_LIBS:+:$IDRIS2_LIBS}"
            echo "Run 'build' to compile amon, or 'idris2 --build amon.ipkg'"
          '';
        };
      }
    );
}
