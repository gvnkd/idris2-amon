{
  description = "amon — Ansible Monitor TUI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    idris2-withpkgs.url = "github:gvnkd/flake-idris2-withPackages";
    nix-bundle.url = "github:matthewbauer/nix-bundle";
    nix-bundle.inputs.nixpkgs.follows = "nixpkgs";

    # Patched upstream linux lib: retry epoll_wait/epoll_pwait2 on EINTR.
    # This fixes the Docker/bundle TUI crash caused by unhandled EINTR.
    idris2-linux-patched = {
      url = "https://github.com/stefan-hoeck/idris2-linux/archive/f34c638ce71f0a46b8b0ef471e2a43e9a91a5853.tar.gz";
      flake = false;
    };

    # Patched async-epoll lib: retry epollPwait2Vals on EINTR in the event loop.
    idris2-async-epoll-patched = {
      url = "https://github.com/stefan-hoeck/idris2-async/archive/1cd4007efcce51efc79c2697a925608826f9d75d.tar.gz";
      flake = false;
    };
    # Patched tui-async lib: add PageUp/PageDown key decoding.
    idris2-tui-async-patched = {
      url = "https://github.com/stefan-hoeck/idris2-tui/archive/aac912e4581dc3fb8b02e12bb984006500d6c2bb.tar.gz";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, idris2-withpkgs, nix-bundle, idris2-linux-patched, idris2-async-epoll-patched, idris2-tui-async-patched }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      idrisPkgs = idris2-withpkgs.packages.${system};

        tuiPatched = (pkgs.idris2Packages.buildIdris {
          src = idris2-tui-async-patched;
          ipkgName = "tui";
          version = "0.1.0-pageup-pagedown-patch";
          idrisLibraries = with idrisPkgs; [
            ansi
            json
            elab-util
            quantifiers-extra
          ];
          patches = [ ./patches/tui-key-pageup-pagedown.patch ];
          nativeBuildInputs = [ pkgs.gcc ];
          postInstall = ''
            mkdir -p $out/lib
            cp lib/*.so $out/lib/ 2>/dev/null || true
          '';
        }).library { withSource = true; };

      # tui-async must be compiled against the patched tui so it sees
      # the PageUp/PageDown constructors; overrideAttrs cannot replace
      # buildIdris dependencies, so rebuild it from the patched source.
      tuiAsyncPatched = (pkgs.idris2Packages.buildIdris {
        src = idris2-tui-async-patched;
        ipkgName = "tui-async";
        version = "0.1.0-pageup-pagedown-patch";
        idrisLibraries = [
          tuiPatched
          idrisPkgs.posix
          idrisPkgs.async
          idrisPkgs.async-epoll
        ];
        preBuild = "cd tui-async";
      }).library { withSource = true; };

      idrisLibraries = with idrisPkgs; [
        json
        elab-util
        ansi
        optparse-applicative
        tuiPatched
        tuiAsyncPatched
        (linux.overrideAttrs (old: {
          version = "0.1.0-eintr-patch";
          src = idris2-linux-patched;
          patches = (old.patches or []) ++ [ ./patches/linux-eintr-retry.patch ];
        }))
        (async-epoll.overrideAttrs (old: {
          version = "0.1.0-eintr-patch";
          src = idris2-async-epoll-patched;
          patches = (old.patches or []) ++ [ ./patches/async-epoll-eintr-retry.patch ];
        }))
        (async-posix.overrideAttrs (old: {
          version = "0.1.0-eintr-patch";
          patches = (old.patches or []) ++ [ ./patches/async-posix-eintr-retry.patch ];
        }))
        streams
        streams-posix
      ];

      idris2Wrapped = idris2-withpkgs.lib.${system}.withPackages (p: [
        p.json
        p.elab-util
        p.ansi
        p.optparse-applicative
        tuiPatched
        tuiAsyncPatched
        (p.linux.overrideAttrs (old: {
          version = "0.1.0-eintr-patch";
          src = idris2-linux-patched;
          patches = (old.patches or []) ++ [ ./patches/linux-eintr-retry.patch ];
        }))
        (p.async-epoll.overrideAttrs (old: {
          version = "0.1.0-eintr-patch";
          src = idris2-async-epoll-patched;
          patches = (old.patches or []) ++ [ ./patches/async-epoll-eintr-retry.patch ];
        }))
        (p.async-posix.overrideAttrs (old: {
          version = "0.1.0-eintr-patch";
          patches = (old.patches or []) ++ [ ./patches/async-posix-eintr-retry.patch ];
        }))
        p.streams
        p.streams-posix
      ]);

        pkg = pkgs.idris2Packages.buildIdris {
          src = ./.;
          ipkgName = "amon";
          version = "0.1.0";
          inherit idrisLibraries;
          nativeBuildInputs = [ pkgs.gcc ];
          meta.mainProgram = "amon";
        };

        # Include transitive dependency lib dirs so Chez dlopen can find
        # support libraries like cptr-idris.so, elin-idris.so, etc.
        depLibPath = pkgs.lib.makeSearchPath "lib" pkg.executable.propagatedIdrisLibraries;

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
                if [ -f "${./.}/support/$base" ] || [ -f "${./.}/support/$base.c" ]; then
                  # buildIdris wraps all .so files with makeBinaryWrapper;
                  # point the symlink at the unwrapped ELF shared object so
                  # Chez Scheme's dlopen can load it.
                  if [ -f "$out/bin/.$base-wrapped" ]; then
                    ln -s "../bin/.$base-wrapped" "$out/lib/$base.so"
                  else
                    ln -s "$f" "$out/lib/$base.so"
                  fi
                fi
              fi
            done
            # Add dependency and local lib dirs to LD_LIBRARY_PATH in wrappers
            for prog in $out/bin/*; do
              if [ -f "$prog" ] && [ -x "$prog" ] && [ ! -L "$prog" ]; then
                base=$(basename "$prog")
                # Don't wrap support libraries — they must remain valid ELF shared
                # objects so Chez Scheme's dlopen can load them.
                if [ ! -f "${./.}/support/$base" ] && [ ! -f "${./.}/support/$base.c" ]; then
                  wrapProgram "$prog" \
                    --prefix LD_LIBRARY_PATH ':' "$out/lib:${depLibPath}"
                fi
              fi
            done
          '';
        });

        buildScript = pkgs.writeShellScriptBin "build" ''
          set -e
          idris2 --build amon.ipkg
          echo "Build complete."
        '';

        container = pkgs.dockerTools.buildLayeredImage {
          name = "amon";
          tag = "latest";
          contents = [
            executable
            pkgs.tini
            pkgs.coreutils
            pkgs.bash
            pkgs.ansible
          ];
          config = {
            Entrypoint = [ "${pkgs.tini}/bin/tini" "--" "${executable}/bin/amon" ];
          };
        };
      in
      {
        packages = {
          default = executable;
          lib = pkg.library';
          inherit container;
        };

        bundlers = {
          default = nix-bundle.bundlers.${system}.default;
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
