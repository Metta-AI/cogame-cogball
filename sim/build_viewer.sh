#!/usr/bin/env bash
# Build the replay viewer from sim/viewer_main.c + sim/cogball_core.c:
#
#   viewer/dist/cogball_viewer.{js,wasm}   browser bundle (-DCOGBALL_RENDER,
#       raylib web) plus index.html, static_replay.js and sim_sha.js
#   build/viewer_core.{js,wasm}            headless core (no raylib,
#       ENVIRONMENT=node) for tests/test_determinism.py and test_viewer.py
#
# Both are compiled from the SAME physics core the server hosts, with the
# same flags and no -ffast-math, which is what makes the cross-build digest
# equality in tests/test_determinism.py hold.
#
# raylib: the exact prebuilt web artifact, sha256-verified and cached in
# build/raylib-web/ (the same pin the cogame-moba starter uses).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v emcc >/dev/null 2>&1; then
    echo "error: emcc not found on PATH - install emscripten" >&2
    exit 1
fi

RAYLIB_DIR=build/raylib-web
RAYLIB_ZIP_URL="https://github.com/raysan5/raylib/releases/download/5.5/raylib-5.5_webassembly.zip"
RAYLIB_ZIP_SHA256="798b6bea650e78a60fe49f106a15d92ea4e33efd3aa1b3efa34b0438a14bbf2c"

# The cache guard includes the pin: a sha bump invalidates a stale tree.
RAYLIB_STAMP="$RAYLIB_DIR/.zip-sha256"
if [ ! -f "$RAYLIB_DIR/lib/libraylib.a" ] || \
   [ "$(cat "$RAYLIB_STAMP" 2>/dev/null)" != "$RAYLIB_ZIP_SHA256" ]; then
    echo "Fetching raylib-5.5_webassembly ..."
    mkdir -p build
    tmpzip="$(mktemp "${TMPDIR:-/tmp}/raylib-web.zip.XXXXXX")"
    trap 'rm -f "$tmpzip"' EXIT
    curl -fsSL --retry 3 "$RAYLIB_ZIP_URL" -o "$tmpzip"
    echo "$RAYLIB_ZIP_SHA256  $tmpzip" | shasum -a 256 -c - >/dev/null
    rm -rf "$RAYLIB_DIR" build/raylib-5.5_webassembly
    (cd build && unzip -q "$tmpzip")
    mv build/raylib-5.5_webassembly "$RAYLIB_DIR"
    printf '%s\n' "$RAYLIB_ZIP_SHA256" > "$RAYLIB_STAMP"
    rm -f "$tmpzip"
    trap - EXIT
fi

VIEWER_EXPORTS=_viewer_load,_viewer_seek,_viewer_step,_viewer_advance,_viewer_advance_frame,_viewer_render_phase,_viewer_tick,_viewer_total_ticks,_viewer_set_speed,_viewer_get_speed,_viewer_set_playing,_viewer_playing,_viewer_done,_viewer_winner,_viewer_goals,_viewer_state_digest,_malloc,_free

MEM_FLAGS=(-sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=256MB -sABORTING_MALLOC=1
           -sINITIAL_MEMORY=64MB -sSTACK_SIZE=512KB)

mkdir -p viewer/dist build

# -- browser bundle (render build) -------------------------------------------
emcc -O2 -DCOGBALL_RENDER -DPLATFORM_WEB -DGRAPHICS_API_OPENGL_ES3 \
    -Isim -I "$RAYLIB_DIR/include" \
    sim/viewer_main.c sim/cogball_core.c "$RAYLIB_DIR/lib/libraylib.a" \
    -sUSE_GLFW=3 -sUSE_WEBGL2=1 \
    "${MEM_FLAGS[@]}" \
    -sENVIRONMENT=web \
    -sEXPORTED_FUNCTIONS="_main,_viewer_set_heat,$VIEWER_EXPORTS" \
    -sEXPORTED_RUNTIME_METHODS=ccall,cwrap,HEAPU8 \
    -o viewer/dist/cogball_viewer.js

cp viewer/index.html viewer/dist/index.html
cp viewer/static_replay.js viewer/dist/static_replay.js

# Embed the sha of the sim wasm this viewer was built alongside; the shell
# warns on screen when a replay's sim_core_sha256 differs. The build order
# (build_sim.sh before build_viewer.sh, as in the Dockerfile and CI) makes
# build/cogball_sim.wasm the matching module.
if [ -f build/cogball_sim.wasm ]; then
    sim_sha="$(shasum -a 256 build/cogball_sim.wasm | cut -d' ' -f1)"
    printf 'window.SIM_CORE_SHA256 = "%s";\n' "$sim_sha" \
        > viewer/dist/sim_sha.js
else
    echo "build/cogball_sim.wasm absent: sha-mismatch warning disabled" >&2
    printf 'window.SIM_CORE_SHA256 = null;\n' > viewer/dist/sim_sha.js
fi

# -- headless core (node verification build) ---------------------------------
emcc -O2 \
    -Isim \
    sim/viewer_main.c sim/cogball_core.c \
    --no-entry \
    "${MEM_FLAGS[@]}" \
    -sENVIRONMENT=node \
    -sMODULARIZE=1 -sEXPORT_NAME=createViewerCore \
    -sEXPORTED_FUNCTIONS="$VIEWER_EXPORTS" \
    -sEXPORTED_RUNTIME_METHODS=ccall,cwrap,HEAPU8 \
    -o build/viewer_core.js

ls -la viewer/dist build/viewer_core.*
echo "build_viewer: OK"
