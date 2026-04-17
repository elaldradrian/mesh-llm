{
  description = "mesh-llm — distributed LLM inference over QUIC";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      rust-overlay,
      crane,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };
        inherit (pkgs) lib stdenv;

        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [
            "rust-src"
            "clippy"
            "rustfmt"
            "rust-analyzer"
          ];
        };

        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        nativeBuildInputs =
          with pkgs;
          [
            rustToolchain
            cmake
            ninja
            pkg-config
            git
            just
            protobuf
            nodejs_24
            python3
            sccache
          ]
          ++ lib.optionals stdenv.isLinux [
            dbus
            openssl
            llvmPackages.clang
          ];

        buildInputs = lib.optionals stdenv.isLinux (
          with pkgs;
          [
            dbus
            openssl
          ]
        );

        mesh-llm-ui = pkgs.buildNpmPackage {
          pname = "mesh-llm-ui";
          version = "0.0.1";
          src = ./mesh-llm/ui;
          npmDepsHash = "sha256-YKoOTbAbgafk04xHuZ1TuVE/n3qGrdHtRelPyRx2nTs=";
          npmDepsFetcherVersion = 2;
          NODE_OPTIONS = "--max-old-space-size=4096";
          buildPhase = ''
            runHook preBuild
            npx tsc --noEmit
            npx vite build
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            cp -r dist $out
            runHook postInstall
          '';
        };

        src = lib.cleanSourceWith {
          src = craneLib.path ./.;
          filter =
            path: type:
            (lib.hasSuffix ".proto" path)
            || (lib.hasSuffix ".json" path)
            || (lib.hasSuffix ".sh" path)
            || (lib.hasSuffix ".md" path)
            || (craneLib.filterCargoSources path type);
        };

        commonArgs = {
          inherit src buildInputs nativeBuildInputs;
          doCheck = false;
          preBuild = ''
            mkdir -p mesh-llm/ui
            cp -r ${mesh-llm-ui} mesh-llm/ui/dist
          '';
        };

        mesh-llm = craneLib.buildPackage (
          commonArgs
          // {
            pname = "mesh-llm";
            cargoExtraArgs = "-p mesh-llm";
          }
        );

        llamaCppForkSrc = pkgs.fetchFromGitHub {
          owner = "Mesh-LLM";
          repo = "llama.cpp";
          rev = "ed2adb0df61f9a58a233899e143e62fa2310ee63";
          hash = "sha256-CwKt5q0IAQTxW7p5YA2RV+pKINUO3XbYPVSHH6mAtXI=";
        };

        mkLlamaCpp =
          overrides:
          (pkgs.llama-cpp.override overrides).overrideAttrs (_old: {
            src = llamaCppForkSrc;
            pname = "llama-cpp-mesh-" + builtins.substring 0 8 llamaCppForkSrc.rev;
            version = "0";
          });

        mkVariant =
          name: overrides:
          let
            baseOverrides = {
              metalSupport = false;
            }
            // overrides;
            llamaServer = mkLlamaCpp (baseOverrides // { rpcSupport = false; });
            llamaRpc = mkLlamaCpp (baseOverrides // { rpcSupport = true; });
          in
          pkgs.symlinkJoin {
            name = "mesh-llm-${name}";
            paths = [
              mesh-llm
              llamaServer
              llamaRpc
            ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              rm -f $out/bin/rpc-server
              makeWrapper ${llamaRpc}/bin/llama-rpc-server $out/bin/rpc-server \
                --prefix DYLD_FALLBACK_LIBRARY_PATH : ${llamaRpc}/lib
            '';
          };

        mesh-llm-cpu = mkVariant "cpu" { metalSupport = false; };
        mesh-llm-metal = mkVariant "metal" { metalSupport = true; };
        mesh-llm-vulkan = mkVariant "vulkan" {
          vulkanSupport = true;
          metalSupport = false;
        };
        mesh-llm-cuda = mkVariant "cuda" {
          cudaSupport = true;
          cudaPackages = pkgs.cudaPackages_12_8;
          metalSupport = false;
        };

        mkApp = drv: {
          type = "app";
          program = "${drv}/bin/mesh-llm";
        };
      in
      {
        packages = {
          default = mesh-llm-cpu;
          inherit
            mesh-llm-cpu
            mesh-llm-metal
            mesh-llm-vulkan
            mesh-llm-cuda
            ;
        };

        apps = {
          default = mkApp mesh-llm-cpu;
          mesh-llm-cpu = mkApp mesh-llm-cpu;
          mesh-llm-metal = mkApp mesh-llm-metal;
          mesh-llm-vulkan = mkApp mesh-llm-vulkan;
          mesh-llm-cuda = mkApp mesh-llm-cuda;
        };

        checks = {
          cargo-test = craneLib.cargoTest (commonArgs // { cargoTestExtraArgs = "--lib -p mesh-llm"; });
          cargo-clippy = craneLib.cargoClippy (
            commonArgs // { cargoClippyExtraArgs = "-p mesh-llm -- -D warnings"; }
          );
          cargo-fmt = craneLib.cargoFmt { inherit src; };
        };

        devShells.default = pkgs.mkShell {
          inherit buildInputs;
          nativeBuildInputs =
            nativeBuildInputs
            ++ (with pkgs; [
              cargo-watch
              cargo-edit
              cargo-nextest
              llama-cpp
            ])
            ++ lib.optionals stdenv.isLinux (
              with pkgs;
              [
                vulkan-headers
                vulkan-loader
                shaderc
              ]
            );

          PKG_CONFIG_PATH = lib.optionalString stdenv.isLinux "${pkgs.dbus.dev}/lib/pkgconfig:${pkgs.openssl.dev}/lib/pkgconfig";

          RUSTC_WRAPPER = "${pkgs.sccache}/bin/sccache";

          shellHook = ''
            if [ -z "$DIRENV_IN_ENVRC" ]; then
              echo "mesh-llm dev shell"
              echo "  Rust  : $(rustc --version)"
              echo "  Cargo : $(cargo --version)"
              echo "  Node  : $(node --version)"
              echo "  CMake : $(cmake --version | head -1)"
              echo "  just  : $(just --version)"
            fi
          '';
        };
      }
    );
}
