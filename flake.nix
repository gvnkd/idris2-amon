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

        pkg = pkgs.idris2Packages.buildIdris {
          src = ./.;
          ipkgName = "amon";
          version = "0.1.0";
          inherit idrisLibraries;
          nativeBuildInputs = [ pkgs.gcc ];
        };

        # Wrap executable with LD_LIBRARY_PATH pointing to lib dir
        # and create .so symlinks so Chez dlopen can find FFI libs
        executable = pkg.executable.overrideAttrs (old: {
          postFixup = ''
            ${old.postFixup or ""}
            # Create .so symlinks in $out/lib for Chez FFI loader
            mkdir -p $out/lib
            for f in $out/bin/*; do
              if [ -f "$f" ] && [ ! -L "$f" ] && [ -x "$f" ]; then
                base=$(basename "$f")
                # Check if there's a corresponding .so source
                if [ -f "${./.}/support/$base" ] || [ -f "${./.}/support/$base.c" ]; then
                  ln -s "$f" "$out/lib/$base.so"
                fi
              fi
            done
            # Add $out/lib to LD_LIBRARY_PATH in all wrappers
            for prog in $out/bin/*; do
              if [ -f "$prog" ] && [ -x "$prog" ] && [ ! -L "$prog" ]; then
                wrapProgram "$prog" \
                  --prefix LD_LIBRARY_PATH ':' "$out/lib"
              fi
            done
          '';
        });

        buildScript = pkgs.writeShellScriptBin "build" ''
          set -e
          idris2 --build amon.ipkg
          echo "Build complete."
        '';
      in
      {
        packages = {
          default = executable;
          lib = pkg.library';
        };

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
