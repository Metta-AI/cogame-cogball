{
  description = "Coworld CTF — Nim capture-the-flag game server, bots, and tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # caos build/agent daemon + CLI. Brings its own pinned nixpkgs (rust-overlay
    # + crane); left un-followed on purpose so its Rust workspace substitutes
    # from cache rather than rebuilding against ours.
    caos.url = "github:Metta-AI/caos";

    # Nimby is the project's dependency manager (see README / Dockerfile). It is
    # a single-file, stdlib-only Nim program, so we build it from source instead
    # of downloading the release binary (which does not run unpatched on Nix).
    nimby-src = {
      url = "github:treeform/nimby/0.1.26";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, caos, nimby-src }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems
          (system: f system (import nixpkgs { inherit system; }));
    in
    {
      packages = forAllSystems (system: pkgs: rec {
        # `nimby use <ver>` is unnecessary here — the shell already provides
        # nim 2.2.10 from nixpkgs — but `nimby sync -g nimby.lock` is how the
        # pinned deps in nimby.lock get cloned into ~/.nimby/pkgs.
        nimby = pkgs.stdenv.mkDerivation {
          pname = "nimby";
          version = "0.1.26";
          src = nimby-src;

          nativeBuildInputs = [ pkgs.nim pkgs.makeWrapper ];

          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR"
            nim c -d:release --hints:off \
              --nimcache:"$TMPDIR/nimcache" \
              -o:nimby src/nimby.nim
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm755 nimby "$out/bin/nimby"
            # nimby shells out to git (clone/fetch/checkout) and curl (Nim
            # tarballs, packages.json).
            wrapProgram "$out/bin/nimby" \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.curl ]}
            runHook postInstall
          '';

          meta = {
            description = "Nim package manager used by coworld-ctf (nimby.lock)";
            homepage = "https://github.com/treeform/nimby";
            license = pkgs.lib.licenses.mit;
            mainProgram = "nimby";
          };
        };

        default = nimby;

        # Re-exported so `nix build .#caos-tools` works from this repo without
        # spelling out the upstream flake ref. The rest of caos's package set
        # (images, worker tarballs) stays upstream — merging it in wholesale
        # would let its `default` silently take over ours.
        inherit (caos.packages.${system}) caos-tools;
      });

      devShells = forAllSystems (system: pkgs:
        let
          inherit (pkgs) lib stdenv;

          python = pkgs.python3.withPackages (ps: with ps; [
            # tools/proxy_harness_binary.py, tools/jitter_harness.py
            fastapi
            uvicorn
            websockets
            # scripts/campaign_puddles.py (optional import)
            pyyaml
            # tools/ci/test_next_coworld_version.py
            pytest
          ]);

          # A `gcc` that is really ccache. Nim resolves its C compiler by NAME on
          # PATH (`gcc.exe = "gcc"`), so shadowing it is what gets ccache into
          # the build — there is no nim flag to set once and forget.
          #
          # Worth it because Nim regenerates byte-identical C on a forced
          # rebuild: measured on this repo, `nim c -f src/ctf.nim` goes 15.5s ->
          # 4.1s with 133/133 ccache hits, the residual being the single-threaded
          # Nim frontend (3.9s) plus the link. On a distro this happens by
          # accident (Debian's ccache package prepends /usr/lib/ccache to PATH);
          # in a nix shell nothing does it for us.
          #
          # NOTE the condition: the generated C embeds absolute paths, so hits
          # require a STABLE --nimcache. Different nimcache dirs miss 100%.
          ccacheGcc = pkgs.runCommand "nim-ccache-gcc" { } ''
            mkdir -p $out/bin
            for tool in gcc cc g++ c++; do
              cat > $out/bin/$tool <<EOF
            #!/bin/sh
            exec ${pkgs.ccache}/bin/ccache ${pkgs.stdenv.cc}/bin/$tool "\$@"
            EOF
              chmod +x $out/bin/$tool
            done
          '';

          # curly/libcurl load libcurl at runtime via dynlib, and pixie/zippy
          # want zlib around. On Linux, windy/paddy (pulled in by nimby.lock)
          # link X11/GL/udev/evdev — CI installs libudev-dev + libevdev-dev for
          # exactly this reason.
          runtimeLibs = [ pkgs.curl.out pkgs.zlib ]
            ++ lib.optionals stdenv.hostPlatform.isLinux (with pkgs; [
              udev
              libevdev
              libGL
              libx11
              libxcursor
              libxi
              libxrandr
              libxext
            ]);
        in
        {
          default = pkgs.mkShell {
            name = "coworld-ctf";

            packages = [
              # Nim toolchain. nixpkgs-unstable ships 2.2.10, the version the
              # README pins via `nimby use 2.2.10` (ctf.nimble needs >= 2.2.4).
              pkgs.nim
              self.packages.${system}.nimby

              # Nim compiles through a C compiler and links with pkg-config.
              ccacheGcc
              pkgs.ccache
              pkgs.pkg-config
              pkgs.git
              pkgs.curl

              # tools/*.cjs QA harnesses and the wasm replay-viewer smoke test.
              pkgs.nodejs_22

              # caos, caos-cli, caosd and caos-runnerd on PATH in one package —
              # the consumption path caos's own flake documents. Built against
              # caos's pinned nixpkgs, NOT ours: a `follows` here would rebuild
              # the whole Rust workspace instead of substituting it.
              caos.packages.${system}.caos-tools

              python
            ];

            # Headers/libs for `nim c` when a dep links C libraries.
            buildInputs = runtimeLibs;

            env = {
              # curly resolves libcurl.so.4 at runtime, not link time.
              LD_LIBRARY_PATH = lib.makeLibraryPath runtimeLibs;
            };

            # Quiet under direnv / `nix develop --command` — only greet a
            # real interactive terminal.
            shellHook = ''
              if [ -t 1 ]; then
                echo "coworld-ctf dev shell — nim $(nim --version | head -1 | cut -d' ' -f4), node $(node --version), python $(python3 --version | cut -d' ' -f2)"
                if [ ! -f nim.cfg ]; then
                  echo
                  echo "  nim.cfg is missing — sync the pinned Nim deps first:"
                  echo "    nimby sync -g nimby.lock"
                fi
                cat <<'EOF'

  run server   COGAME_HOST=0.0.0.0 COGAME_PORT=2000 \
                 COGAME_CONFIG_URI=file://$PWD/config.json nim r src/ctf.nim
  run tests    nim c -r tests/tests.nim            (from the repo root)
  baseline bot nim c players/baseline/baseline.nim
  map editor   nim c --threads:on --mm:orc -r tools/map_editor.nim 8099
  replay dump  nim r tools/expand_replay.nim tests/replays/<file>.bitreplay

  gcc is ccache-wrapped: a forced rebuild (nim c -f) is ~4s instead of ~15s
  once warm. Hits need a STABLE --nimcache (paths are baked into the C).

  The static replay viewer (wasm) builds through Docker —
  Dockerfile.replay-viewer pins emsdk; use tools/build_replay_viewer.sh.

EOF
              fi
            '';
          };
        });
    };
}
