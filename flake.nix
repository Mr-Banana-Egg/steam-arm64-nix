{
  description = "Valve's aarch64 Steam client packaged for NixOS - pinned from Valve's own client manifest";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    std = {
      url = "github:Daaboulex/nix-packaging-standard?ref=v2.40.1";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.git-hooks.follows = "git-hooks";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "aarch64-linux" ];

      imports = [ inputs.std.flakeModules.base ];

      perSystem =
        { system, self', ... }:
        let
          pkgs = import inputs.nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        in
        {
          packages.steam-arm64-client = pkgs.callPackage ./package.nix { channel = "stable"; };
          packages.steam-arm64-client-beta = pkgs.callPackage ./package.nix { channel = "publicbeta"; };
          packages.default = self'.packages.steam-arm64-client;
          packages.libdbusmenu-gtk2 = pkgs.callPackage ./libdbusmenu-gtk2.nix { };
          packages.libappindicator-gtk2 = pkgs.callPackage ./libappindicator-gtk2.nix {
            inherit (self'.packages) libdbusmenu-gtk2;
          };
          packages.steam-runtime-arm64 = pkgs.callPackage ./runtime.nix { };
          packages.steam-arm64-fhs = pkgs.callPackage ./fhs.nix {
            inherit (self'.packages) steam-runtime-arm64;
            inherit (self'.packages) libappindicator-gtk2;
          };
          packages.steam-x86-rootfs = pkgs.callPackage ./fex-rootfs-x86.nix { };
          packages.fex-emulator-x86 = pkgs.callPackage ./fex-emulator-x86.nix { };
          packages.steam-x86-fhs = pkgs.callPackage ./fhs-x86.nix {
            steam-x86-entry = pkgs.steam-unwrapped;
            inherit (self'.packages) fex-emulator-x86;
          };
          packages.steam-x86 = pkgs.callPackage ./launcher-x86.nix {
            muvm = pkgs.callPackage ./muvm-patched.nix { };
            inherit (self'.packages)
              steam-x86-rootfs
              steam-x86-fhs
              fex-emulator-x86
              ;
          };

          packages.steam-arm64 = pkgs.callPackage ./launcher.nix {
            muvm = pkgs.callPackage ./muvm-patched.nix { };
            channel = "stable";
            inherit (self'.packages) steam-arm64-client steam-arm64-fhs steam-x86-rootfs;
          };
          packages.steam-arm64-beta = pkgs.callPackage ./launcher.nix {
            muvm = pkgs.callPackage ./muvm-patched.nix { };
            channel = "publicbeta";
            steam-arm64-client = self'.packages.steam-arm64-client-beta;
            inherit (self'.packages) steam-arm64-fhs steam-x86-rootfs;
          };

          pre-commit.settings.hooks = {
            trim-trailing-whitespace.excludes = [ "\\.patch$" ];
            end-of-file-fixer.excludes = [ "\\.patch$" ];
            typos.excludes = [ "\\.patch$" ];
            typos.settings.config.default.extend-words.passt = "passt";
          };

          checks.muvm-patches-apply =
            let
              patched = pkgs.callPackage ./muvm-patched.nix { };
            in
            pkgs.runCommand "muvm-patches-apply" { nativeBuildInputs = [ pkgs.gnupatch ]; } ''
              cp -r ${patched.src} src
              chmod -R +w src
              cd src
              patch -p1 <${./muvm-mask-mit-shm.patch}
              patch -p1 <${./muvm-bridge-dbus.patch}
              patch -p1 <${./muvm-vm-tuning.patch}
              patch -p1 <${./muvm-guest-groups.patch}
              touch "$out"
            '';

          checks.muvm-shm-divergence = pkgs.runCommand "muvm-shm-divergence" { } ''
            if grep -q MIT-SHM ${pkgs.muvm.src}/crates/muvm/src/guest/bridge/x11.rs; then
              echo "muvm ${pkgs.muvm.version} now names MIT-SHM in its own X11 bridge."
              echo "Read what it does there. If it masks or proxies the extension,"
              echo "delete muvm-mask-mit-shm.patch, its override in launcher.nix, and this check."
              exit 1
            fi
            touch "$out"
          '';

          checks.muvm-groups-divergence = pkgs.runCommand "muvm-groups-divergence" { } ''
            if grep -q setgroups ${pkgs.muvm.src}/crates/muvm/src/guest/user.rs; then
              echo "muvm ${pkgs.muvm.version} now sets the supplementary groups itself."
              echo "Read what it claims. If the command in the vm ends up in the host's"
              echo "input group, delete muvm-guest-groups.patch, its line in"
              echo "muvm-patched.nix and in muvm-patches-apply, and this check."
              exit 1
            fi
            touch "$out"
          '';

          checks.tray-library = pkgs.runCommand "steam-arm64-tray-library" { } ''
            rootfs=$(grep -ao '/nix/store/[a-z0-9]*-steam-arm64-fhs-fhsenv-rootfs' \
              ${self'.packages.steam-arm64-fhs}/bin/steam-arm64-fhs | head -1)
            test -n "$rootfs"
            test -e "$rootfs/usr/lib64/libappindicator.so.1"
            touch "$out"
          '';

          checks.runtime-tools = pkgs.runCommand "steam-arm64-runtime-tools" { } ''
            test -x ${self'.packages.steam-runtime-arm64}/bin/steam-runtime-launcher-service
            test -d ${self'.packages.steam-runtime-arm64}/pressure-vessel
            rootfs=$(grep -ao '/nix/store/[a-z0-9]*-steam-arm64-fhs-fhsenv-rootfs' \
              ${self'.packages.steam-arm64-fhs}/bin/steam-arm64-fhs | head -1)
            test -n "$rootfs"
            grep -q '${self'.packages.steam-runtime-arm64}/bin' "$rootfs/etc/profile"
            test -e "$rootfs/usr/bin/fusermount3"
            touch "$out"
          '';

          checks.overlay-resolves =
            let
              overlaid = import inputs.nixpkgs {
                inherit system;
                config.allowUnfree = true;
                overlays = [ inputs.self.overlays.default ];
              };
            in
            pkgs.runCommand "steam-arm64-overlay-resolves" { } ''
              test -x ${overlaid.steam-arm64}/bin/steam-arm64
              test -x ${overlaid.steam-arm64-beta}/bin/steam-arm64
              test -x ${overlaid.steam-arm64-fhs}/bin/steam-arm64-fhs
              touch "$out"
            '';

          checks.cursor-path-forwarded = pkgs.runCommand "steam-cursor-path-forwarded" { } ''
            status=0
            for l in ${./launcher.sh} ${./launcher-x86.sh}; do
              if ! grep -q 'XCURSOR_PATH' "$l"; then
                echo "$l does not hand XCURSOR_PATH to the guest"
                status=1
              fi
            done
            if [ "$status" -ne 0 ]; then
              echo "libXcursor here searches only the home directory and its own empty share"
              echo "directory, so the theme the desktop names resolves in the guest only through"
              echo "the XCURSOR_PATH the session publishes; without it every lookup falls to the"
              echo "X server's built-in bitmap, 10x16 pixels whatever the display scale."
              exit 1
            fi
            touch "$out"
          '';

          checks.one-entry-owns-the-window-class =
            pkgs.runCommand "steam-one-entry-owns-the-window-class" { }
              ''
                grep -q 'startupWMClass = "steam"' ${./launcher.nix} \
                  || {
                    echo "the native client's desktop entry must claim the window class steam"
                    exit 1
                  }
                if grep -q -E 'startupWMClass|mimeTypes' ${./launcher-x86.nix}; then
                  echo "the x86 client's desktop entry must not claim the window class or the"
                  echo "steam URL scheme: both clients open windows of class steam, and a second"
                  echo "claim makes the task manager name the native client's window after it"
                  exit 1
                fi
                touch "$out"
              '';

          checks.remote-play-ports-published = pkgs.runCommand "steam-remote-play-ports-published" { } ''
            for l in ${./launcher.sh} ${./launcher-x86.sh}; do
              for p in 27031:27031/udp 27036:27036/udp 27036:27036 27037:27037; do
                if ! grep -q -- "-p $p" "$l"; then
                  echo "$l no longer publishes $p: passt cannot carry the guest's own LAN"
                  echo "broadcast, so a Steam Link or Remote Play client on the LAN finds this"
                  echo "client only through the published discovery and stream ports"
                  exit 1
                fi
              done
            done
            touch "$out"
          '';

          checks.join-stdin-epollable = pkgs.runCommand "steam-join-stdin-epollable" { } ''
            status=0
            for l in ${./launcher.sh} ${./launcher-x86.sh}; do
              if ! grep -qF 'exec < <(:)' "$l"; then
                echo "$l hands muvm a stdin it may not be able to watch"
                status=1
              fi
            done
            if [ "$status" -ne 0 ]; then
              echo "muvm's io loop for a launch into a running guest adds its stdin to epoll,"
              echo "which fails with EPERM on /dev/null or a regular file after the request was"
              echo "already sent; a desktop entry or a steam:// link launches with exactly that"
              echo "stdin. Replace it with a pipe at end of file before calling muvm."
              exit 1
            fi
            touch "$out"
          '';

          checks.steam-arm64-x86-games-wiring = pkgs.runCommand "steam-arm64-x86-games-wiring" { } ''
            l=${self'.packages.steam-arm64}/bin/steam-arm64
            grep -q -- '-f "${self'.packages.steam-x86-rootfs}"' "$l" \
              || {
                echo "the native client's guest has no FEX rootfs, so no graphics provider"
                exit 1
              }
            grep -q 'STEAM_COMPAT_GRAPHICS_PROVIDER=/run/fex-emu/rootfs/graphics_provider.json' "$l" \
              || {
                echo "the native client does not name the graphics provider for Valve's FEX tool"
                exit 1
              }
            grep -q 'export PATH="/nix/store/[a-z0-9]*-fex-interpreter/bin:' "$l" \
              || {
                echo "the guest's PATH carries no FEXInterpreter, so muvm registers no x86 binfmt"
                exit 1
              }
            rootfs=$(grep -ao '/nix/store/[a-z0-9]*-steam-arm64-fhs-fhsenv-rootfs' \
              ${self'.packages.steam-arm64-fhs}/bin/steam-arm64-fhs | head -1)
            test -n "$rootfs"
            test -x "$rootfs/usr/bin/python3" \
              || {
                echo "Valve's fex-compat-tool is a python3 script run outside the container;"
                echo "without python3 in the FHS every x86 tool and game exits at once"
                exit 1
              }
            touch "$out"
          '';

          checks.fex-emulator-x86-self-contained =
            pkgs.runCommand "fex-emulator-x86-self-contained" { nativeBuildInputs = [ pkgs.patchelf ]; }
              ''
                b=${self'.packages.fex-emulator-x86}
                test -f "$b/emulator.json"
                interp=$(patchelf --print-interpreter "$b/bin/FEX")
                case "$interp" in
                "$b/lib/"*) ;;
                *)
                  echo "FEX interpreter escapes the bundle: $interp"
                  exit 1
                  ;;
                esac
                rpath=$(patchelf --print-rpath "$b/bin/FEX")
                case "$rpath" in
                "$b/lib"*) ;;
                *)
                  echo "FEX rpath escapes the bundle: $rpath"
                  exit 1
                  ;;
                esac
                touch "$out"
              '';

          checks.fex-multiblock-divergence = pkgs.runCommand "fex-multiblock-divergence" { } ''
            case "${pkgs.fex.version}" in
            2608*) touch "$out" ;;
            *)
              echo "FEX is at ${pkgs.fex.version}, past 2608. PR #5856 (the dynamic L1"
              echo "cache fix behind FEX issue #5336) landed after 2608, so a newer FEX"
              echo "may make the web-helper Multiblock:0 workaround unnecessary. Re-test"
              echo "the web helper without it, then drop the Config.Multiblock block in"
              echo "fex-emulator-x86.nix and this check if it stays stable."
              exit 1
              ;;
            esac
          '';

          checks.fex-launcher-env = pkgs.runCommand "fex-launcher-env" { } ''
            known=$(grep -aoE 'FEX_[A-Z0-9_]+' ${pkgs.fex}/bin/FEX | sort -u)
            status=0
            for f in ${./launcher.sh} ${./launcher-x86.sh} ${./guest-run-x86.sh}; do
              for v in $(grep -aoE 'FEX_[A-Z0-9_]+' "$f" | sort -u); do
                if ! grep -qxF "$v" <<<"$known"; then
                  echo "$v is set by a launcher but FEX ${pkgs.fex.version} does not name it (a silent no-op)"
                  status=1
                fi
              done
            done
            if [ "$status" -ne 0 ]; then exit 1; fi
            touch "$out"
          '';

          checks.steam-x86-fhs-coreutils = pkgs.runCommand "steam-x86-fhs-coreutils" { } ''
            rootfs=$(grep -ao '/nix/store/[a-z0-9]*-steam-x86-fhs-fhsenv-rootfs' \
              ${self'.packages.steam-x86-fhs}/bin/steam-x86-fhs | head -1)
            test -n "$rootfs"
            test -e "$rootfs/usr/bin/true"
            touch "$out"
          '';

          checks.steam-x86-rootfs-erofs = pkgs.runCommand "steam-x86-rootfs-erofs" { } ''
            test "$(od -An -tx1 -j1024 -N4 ${self'.packages.steam-x86-rootfs} | tr -d ' ')" = "e2e1f5e0" \
              || {
                echo "not an EROFS image: ${self'.packages.steam-x86-rootfs}"
                exit 1
              }
            touch "$out"
          '';

          checks.steam-x86-launcher-wiring = pkgs.runCommand "steam-x86-launcher-wiring" { } ''
            l=${self'.packages.steam-x86}/bin/steam-x86
            grep -q '${self'.packages.fex-emulator-x86}/emulator.json' "$l" \
              || {
                echo "launcher does not set the emulator descriptor"
                exit 1
              }
            grep -q '${self'.packages.steam-x86-rootfs}' "$l" \
              || {
                echo "launcher does not mount the rootfs"
                exit 1
              }
            grep -q '${self'.packages.steam-x86-fhs}/bin/steam-x86-fhs' "$l" \
              || {
                echo "launcher does not enter the FHS"
                exit 1
              }
            grep -q 'FEX_ROOTFS=/run/fex-emu/rootfs' ${./guest-run-x86.sh} \
              || {
                echo "guest-run does not set FEX_ROOTFS"
                exit 1
              }
            touch "$out"
          '';

          checks.muvm-guest-path-socat = pkgs.runCommand "muvm-guest-path-socat" { } ''
            status=0
            for l in ${self'.packages.steam-arm64}/bin/steam-arm64 \
              ${self'.packages.steam-x86}/bin/steam-x86; do
              if grep -q '"PATH=' "$l" && ! grep -q '${pkgs.socat}/bin' "$l"; then
                echo "$l hands the guest a PATH with no socat on it."
                status=1
              fi
            done
            if [ "$status" -ne 0 ]; then
              echo "muvm builds its pulse and session bus proxies by running socat, and"
              echo "setup_socket_proxy returns Ok without a word when socat is absent from"
              echo "the PATH the guest inherits, so the guest gets no bridge at all and the"
              echo "tray falls back to an XEmbed icon with no name and no menu. Either leave"
              echo "the guest PATH alone, as the arm64 launcher does, or put socat on the"
              echo "one you set."
              exit 1
            fi
            touch "$out"
          '';

          checks.client-tree = pkgs.runCommand "steam-arm64-client-tree" { } ''
            test -d ${self'.packages.default}/steamrtarm64/libs
            touch "$out"
          '';
        };

      flake.overlays.default = final: prev: {
        muvm = final.callPackage ./muvm-patched.nix { inherit (prev) muvm; };
        libdbusmenu-gtk2 = final.callPackage ./libdbusmenu-gtk2.nix { };
        libappindicator-gtk2 = final.callPackage ./libappindicator-gtk2.nix { };
        steam-arm64-client = final.callPackage ./package.nix { channel = "stable"; };
        steam-arm64-client-beta = final.callPackage ./package.nix { channel = "publicbeta"; };
        steam-runtime-arm64 = final.callPackage ./runtime.nix { };
        steam-arm64-fhs = final.callPackage ./fhs.nix { };
        steam-x86-rootfs = final.callPackage ./fex-rootfs-x86.nix { };
        steam-arm64 = final.callPackage ./launcher.nix { channel = "stable"; };
        steam-arm64-beta = final.callPackage ./launcher.nix {
          channel = "publicbeta";
          steam-arm64-client = final.steam-arm64-client-beta;
        };
      };
    };
}
