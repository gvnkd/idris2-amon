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

    # async-posix source for EINTR retry patch.
    idris2-async-posix-patched = {
      url = "https://github.com/stefan-hoeck/idris2-async/archive/1cd4007efcce51efc79c2697a925608826f9d75d.tar.gz";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, idris2-withpkgs, nix-bundle, idris2-linux-patched, idris2-async-epoll-patched, idris2-tui-async-patched, idris2-async-posix-patched }:
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
            src = idris2-async-posix-patched;
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
            src = idris2-async-posix-patched;
            patches = (old.patches or []) ++ [ ./patches/async-posix-eintr-retry.patch ];
          }))
          p.streams
          p.streams-posix
        ]);

        version = "1.0.0";

        pkg = pkgs.idris2Packages.buildIdris {
          src = ./.;
          ipkgName = "amon";
          inherit version;
          inherit idrisLibraries;
          nativeBuildInputs = [ pkgs.gcc ];
          meta.mainProgram = "amon";
        };

        # Include transitive dependency lib dirs so Chez dlopen can find
        # support libraries like cptr-idris.so, elin-idris.so, etc.
        depLibPath = pkgs.lib.makeSearchPath "lib" pkg.executable.propagatedIdrisLibraries;

        allDepLibDirs = pkgs.lib.concatMapStringsSep " " (p: "${p}/lib") pkg.executable.propagatedIdrisLibraries;

        supportDir = "${pkgs.idris2Packages.idris2.unwrapped.libidris2_support}/lib";

        # Build the unwrapped binary directly; avoid makeBinaryWrapper so the
        # resulting ELF is portable and can be packaged in a .deb.
        executable = pkg.executable.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.makeWrapper ];
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/lib

            scheme_app="$(find ./build/exec -name '*_app')"
            if [ "$scheme_app" = ''' ]; then
              mv -- build/exec/* $out/bin/
              chmod +x $out/bin/*
            else
              cd "$scheme_app"
              rm -f ./libidris2_support.{so,dylib}
              for file in *.so; do
                bin_name="''${file%.so}"
                mv -- "$file" "$out/bin/.$bin_name-wrapped"
                makeWrapper "$out/bin/.$bin_name-wrapped" "$out/bin/$bin_name" \
                  --prefix LD_LIBRARY_PATH ':' "$out/lib:${depLibPath}:${supportDir}"
              done
            fi

            # Symlink all transitive dependency *.so files into $out/lib so
            # Chez Scheme's (load-shared-object) can find them by name.
            for libdir in ${allDepLibDirs}; do
              for so in "$libdir"/*.so; do
                [ -f "$so" ] || continue
                base=$(basename "$so")
                [ -e "$out/lib/$base" ] || ln -s "$so" "$out/lib/$base"
              done
            done

            # Symlink local FFI shared objects (e.g. amon-idris) into $out/lib
            # under their bare basename so dlopen finds them.
            for wrapped in $out/bin/.*-wrapped; do
              [ -f "$wrapped" ] || continue
              base=$(basename "$wrapped")
              libname=''${base#.}
              libname=''${libname%-wrapped}
              if [ -f "${./.}/support/$libname" ] || [ -f "${./.}/support/$libname.c" ]; then
                [ -e "$out/lib/$libname.so" ] || ln -s "$wrapped" "$out/lib/$libname.so"
              fi
            done

            runHook postInstall
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

        amonDeb = pkgs.stdenvNoCC.mkDerivation {
          name = "amon-${version}.deb";
          inherit version;
          nativeBuildInputs = [ pkgs.dpkg pkgs.patchelf pkgs.glibc.bin ];
          dontUnpack = true;
          buildPhase = ''
            mkdir -p amon/DEBIAN
            mkdir -p amon/usr/bin
            mkdir -p amon/usr/lib/amon

            # The Chez backend produces a program object (bin/.amon-wrapped)
            # with a #! shebang to the Chez scheme binary. Ship both the
            # runtime and the program object so amon runs on non-NixOS.
            cp -L ${executable}/bin/.amon-wrapped amon/usr/lib/amon/amon.so
            chmod +w amon/usr/lib/amon/amon.so

            # Extract the exact Chez binary path from the shebang and ship it
            # together with its boot files so the runtime is self-contained.
            chezPath=$(head -1 ${executable}/bin/.amon-wrapped | sed 's|^#!||; s| --program.*||')
            chezStore=$(dirname "$(dirname "$chezPath")")
            cp -L "$chezPath" amon/usr/lib/amon/scheme
            chmod +w amon/usr/lib/amon/scheme
            cp -r "$chezStore/lib" amon/usr/lib/amon/lib
            heapDir=$(dirname "$(find amon/usr/lib/amon/lib -name scheme.boot | head -1)")
            heapDir=''${heapDir#amon}

            # Copy the local FFI shared object(s) (e.g. amon-idris.so).
            cp -L ${executable}/lib/amon-idris.so amon/usr/lib/amon/

            # Collect every transitive Idris FFI *.so (cptr, linux, posix, etc.)
            # and the Idris2 support library into /usr/lib/amon.
            for libdir in ${allDepLibDirs}; do
              for so in "$libdir"/*.so; do
                [ -f "$so" ] || continue
                base=$(basename "$so")
                [ -e "amon/usr/lib/amon/$base" ] || cp -L "$so" "amon/usr/lib/amon/$base"
              done
            done
            cp -L ${pkgs.idris2Packages.idris2.unwrapped.libidris2_support}/lib/libidris2_support.so amon/usr/lib/amon/

            # Ship the shared libraries Chez itself needs.
            for lib in $(ldd "$chezPath" | awk '{print $3}' | grep -E '^/nix/store/' | sort -u); do
              cp -L "$lib" amon/usr/lib/amon/
            done

            # Patch the Chez interpreter so it uses the bundled dynamic linker
            # and glibc (Nix glibc is newer than Debian's) and finds all bundled
            # libraries in /usr/lib/amon.
            patchelf \
              --set-interpreter /usr/lib/amon/ld-linux-x86-64.so.2 \
              --set-rpath '/usr/lib/amon' \
              amon/usr/lib/amon/scheme

            cat > amon/usr/bin/amon <<'WRAPPER'
            #!/usr/bin/env bash
            export SCHEMEHEAPDIRS=/usr/lib/amon/lib/csv10.4.1/ta6le
            # Set LD_LIBRARY_PATH only for the Chez interpreter so that child
            # processes (e.g. /bin/sh) use the host glibc rather than the
            # bundled Nix glibc.
            LD_LIBRARY_PATH=/usr/lib/amon''${LD_LIBRARY_PATH:+:''${LD_LIBRARY_PATH}} \
              exec /usr/lib/amon/scheme --program /usr/lib/amon/amon.so "$@"
            WRAPPER
            chmod 0755 amon/usr/bin/amon

            cat > amon/DEBIAN/control <<'EOF'
            Package: amon
            Version: ${version}
            Section: utils
            Priority: optional
            Architecture: amd64
            Depends: libc6
            Maintainer: Omg Bebebe <amon@omgbebebe.local>
            Description: Ansible Monitor TUI
             amon is a terminal UI for running and monitoring Ansible
             playbooks and other shell tasks.
            EOF

            dpkg-deb --root-owner-group --build amon
          '';
          installPhase = ''
            mkdir -p $out
            cp amon.deb $out/amon_${version}_amd64.deb
          '';
        };
      in
      {
        packages = {
          default = executable;
          lib = pkg.library';
          inherit container amonDeb;
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
