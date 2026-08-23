#!/usr/bin/env bash
# Build the sim wasm the wasmtime host runs:
#
#   build/cogball_sim.wasm    sim/cogball_core.c, WASI reactor
#
# Flags:
#   STANDALONE_WASM + --no-entry : WASI reactor module for wasmtime hosting
#   -O2, and deliberately NO -ffast-math: the physics core's determinism
#     guarantee is that only + - * / sqrt on doubles are used and that
#     WebAssembly specifies them exactly. -ffast-math would let LLVM
#     reassociate and contract, and the emscripten and standalone builds
#     would silently stop agreeing. tests/test_determinism.py greps this
#     file (and build_viewer.sh) for the flag.
# The core allocates nothing, so no memory-growth flags are needed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v emcc >/dev/null 2>&1; then
    echo "error: emcc not found on PATH - install emscripten" >&2
    exit 1
fi

mkdir -p build
emcc -O2 -sSTANDALONE_WASM --no-entry \
    -Isim \
    sim/cogball_core.c \
    -o build/cogball_sim.wasm

ls -la build/cogball_sim.wasm
echo "build_sim: OK"
