{
  description = "SlimeNRF-Tracker - nRF Connect SDK (Zephyr) firmware";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = f: lib.genAttrs systems (system: f system (import nixpkgs { inherit system; }));

      sdkVersion = "1.0.0";

      sdkInfo = {
        x86_64-linux = {
          host = "linux-x86_64";
          hashes = {
            minimal = "sha256-a2mktUtHDjqiHNr5XNyAhDHoynOnuCKjOmguW10sVRI=";
            hosttools = "sha256-U3AoIBkhQFPM3Hv9xis2FquFgVilxIwRGEYRuBiQq0U=";
            toolchain = "sha256-S0Z+L7JjB7RkkV0MmofkerTZTVYIiPI5p27rVrTZAR8=";
          };
        };
        aarch64-linux = {
          host = "linux-aarch64";
          hashes = {
            minimal = "sha256-7gTyLS7LCzvhuEtWPPue5CV4XsgeVMgcP2jBtSDH6OA=";
            hosttools = "sha256-Yf2R90ChpCZ5m/1lOohzwILykx1m5bfqP8H9S0/S1+g=";
            toolchain = "sha256-tshsrqS+4BKUMhfz5gUOblbHgAC26H27ne1KKQ3ONXM=";
          };
        };
      };

      zephyrSdk =
        pkgs: system:
        let
          info = sdkInfo.${system};
          base = "https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v${sdkVersion}";
          fetch =
            {
              name,
              url,
              hash,
            }:
            pkgs.fetchurl { inherit name url hash; };
          minimal = fetch {
            name = "zephyr-sdk-${sdkVersion}_${info.host}_minimal.tar.xz";
            url = "${base}/zephyr-sdk-${sdkVersion}_${info.host}_minimal.tar.xz";
            hash = info.hashes.minimal;
          };
          hosttools = fetch {
            name = "hosttools_${info.host}.tar.xz";
            url = "${base}/hosttools_${info.host}.tar.xz";
            hash = info.hashes.hosttools;
          };
          toolchain = fetch {
            name = "toolchain_gnu_${info.host}_arm-zephyr-eabi.tar.xz";
            url = "${base}/toolchain_gnu_${info.host}_arm-zephyr-eabi.tar.xz";
            hash = info.hashes.toolchain;
          };
        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "zephyr-sdk";
          version = sdkVersion;

          dontBuild = true;
          dontFixup = true;

          nativeBuildInputs = with pkgs; [
            file
            gawk
            gnutar
            python3
            which
            xz
          ];

          unpackPhase = ''
            runHook preUnpack
            mkdir -p minimal toolchain hosttools
            tar xf ${minimal} -C minimal
            tar xf ${toolchain} -C toolchain
            tar xf ${hosttools} -C hosttools
            runHook postUnpack
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out"/gnu "$out"/hosttools
            cp -a minimal/zephyr-sdk-${sdkVersion}/. "$out"/
            cp -a toolchain/arm-zephyr-eabi "$out"/gnu/arm-zephyr-eabi
            cp hosttools/*hosttools-standalone-*.sh "$out"/hosttools/hosttools.sh
            chmod +x "$out"/hosttools/hosttools.sh
            ( cd "$out"/hosttools && ./hosttools.sh -y -d "$out"/hosttools )
            rm -f "$out"/hosttools/hosttools.sh
            runHook postInstall
          '';

          meta = with lib; {
            description = "Zephyr SDK ${sdkVersion} (arm-zephyr-eabi toolchain)";
            homepage = "https://github.com/zephyrproject-rtos/sdk-ng";
            license = licenses.asl20;
            platforms = [
              "x86_64-linux"
              "aarch64-linux"
            ];
          };
        };

      hostTools =
        pkgs:
        (with pkgs; [
          cmake
          ninja
          gperf
          dtc
          ccache
          dfu-util
          wget
          xz
          file
          gnumake
          gcc
          pkg-config
          git
          cacert
          SDL2
          tk
          openocd
          python3
          python3Packages.pip
          python3Packages.setuptools
          python3Packages.virtualenv
        ])
        ++ [ pkgs.python3Packages.west ];

      buildScript =
        system: pkgs:
        let
          sdk = zephyrSdk pkgs system;
          runtimePath = lib.makeBinPath ((hostTools pkgs) ++ [ sdk ]);
        in
        pkgs.writeShellScriptBin "nrf-build" ''
          set -euo pipefail

          REPO="$PWD"
          BOARD="''${1:-''${NRF_BOARD:-promicro_uf2/nrf52840/i2c}}"
          WORKSPACE="''${NRF_WORKSPACE:-$REPO/.ncs}"
          VENV="''${NRF_VENV:-$WORKSPACE/.venv}"
          APP="$WORKSPACE/app"
          BUILD_DIR="''${NRF_BUILD_DIR:-$WORKSPACE/build}"
          PRISTINE="''${NRF_PRISTINE:-always}"
          UPDATE="''${NRF_UPDATE:-1}"

          export PATH="${runtimePath}:$PATH"
          export ZEPHYR_SDK_INSTALL_DIR="''${ZEPHYR_SDK_INSTALL_DIR:-${sdk}}"
          export ZEPHYR_TOOLCHAIN_VARIANT="''${ZEPHYR_TOOLCHAIN_VARIANT:-zephyr}"

          echo ">> Repo:      $REPO"
          echo ">> Board:     $BOARD"
          echo ">> Workspace: $WORKSPACE"
          echo ">> SDK:       $ZEPHYR_SDK_INSTALL_DIR"

          mkdir -p "$WORKSPACE"
          if [ ! -e "$APP" ]; then
            ln -s "$REPO" "$APP"
          fi

          # The Nix Python wrappers export PYTHONPATH, which would shadow the
          # venv's own pip/site-packages. Clear it so the venv is self-contained.
          # Also drop any inherited Zephyr location so the workspace's own
          # Zephyr is always used.
          unset PYTHONPATH
          unset ZEPHYR_BASE ZEPHYR_MODULES

          if [ ! -x "$VENV/bin/python" ]; then
            echo ">> Creating Python venv at $VENV"
            python3 -m venv "$VENV"
          fi

          VENV_PY="$VENV/bin/python"
          "$VENV_PY" -m pip install --quiet --upgrade pip wheel
          "$VENV_PY" -m pip install --quiet west

          cd "$WORKSPACE"

          # Create the workspace config by hand: "west init -l app" follows the
          # app symlink to its real path and would place the workspace in the
          # repo's parent directory. Writing .west/config keeps the top level
          # here while still using the live repo (via the app symlink) as the
          # manifest repository.
          if [ ! -d .west ]; then
            echo ">> Initializing west workspace"
            mkdir -p .west
            printf '%s\n' '[manifest]' 'path = app' 'file = west.yml' > .west/config
            printf '\n%s\n%s\n' '[zephyr]' 'base = zephyr' >> .west/config
          fi

          if [ "$UPDATE" = 1 ]; then
            echo ">> Fetching NCS/Zephyr workspace (this can take a while)"
            "$VENV/bin/west" update --narrow -o=--depth=1
          else
            echo ">> Skipping west update (NRF_UPDATE=$UPDATE)"
          fi

          if [ -f zephyr/scripts/requirements.txt ]; then
            "$VENV_PY" -m pip install --quiet -r zephyr/scripts/requirements.txt
          fi

          # CMake resolves the venv interpreter symlink back to the base Nix
          # Python, so expose the venv packages via PYTHONPATH as well.
          VENV_SITE="$("$VENV_PY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
          export PYTHONPATH="$VENV_SITE"

          "$VENV/bin/west" zephyr-export

          # A build tree left over from a previous (possibly different)
          # workspace bakes in its Zephyr path, and neither a fresh configure
          # nor "west build --pristine" can recover from that. Recreate it.
          if [ "$PRISTINE" = always ]; then
            rm -rf "$BUILD_DIR"
          fi

          echo ">> Building $BOARD"
          "$VENV/bin/west" build app \
            --board "$BOARD" \
            --build-dir "$BUILD_DIR" \
            -- \
            -DNCS_TOOLCHAIN_VERSION=NONE \
            -DBOARD_ROOT="$REPO"

          echo ">> Done. Artifacts:"
          find "$BUILD_DIR" -maxdepth 4 -type f -name 'zephyr.*'
        '';
    in
    {
      packages = forAllSystems (
        system: pkgs: {
          default = buildScript system pkgs;
          zephyr-sdk = zephyrSdk pkgs system;
        }
      );

      apps = forAllSystems (
        system: pkgs: rec {
          build = {
            type = "app";
            program = "${buildScript system pkgs}/bin/nrf-build";
            meta.description = "Set up the NCS west workspace and build the firmware";
          };
          default = build;
        }
      );

      devShells = forAllSystems (
        system: pkgs: {
          default = pkgs.mkShell {
            name = "slimenrf-tracker";

            packages = (hostTools pkgs) ++ [
              (zephyrSdk pkgs system)
              (buildScript system pkgs)
            ];

            env = {
              ZEPHYR_TOOLCHAIN_VARIANT = "zephyr";
              ZEPHYR_SDK_INSTALL_DIR = "${zephyrSdk pkgs system}";
            };

            shellHook = ''
              echo "SlimeNRF-Tracker dev shell"
              echo "  Zephyr SDK: $ZEPHYR_SDK_INSTALL_DIR"
              echo "  Build:      nrf-build [board]   (default: promicro_uf2/nrf52840/i2c)"
              echo "  Or:         nix run .#build -- <board>"
              if [ -f .ncs/.venv/bin/activate ]; then
                # shellcheck disable=SC1091
                source .ncs/.venv/bin/activate
              fi
            '';
          };
        }
      );

      formatter = forAllSystems (system: pkgs: pkgs.nixfmt);
    };
}
