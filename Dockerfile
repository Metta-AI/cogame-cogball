# cogball Coworld image: game server + player in ONE image.
#
# Stage 1 (wasm-builder) compiles the deterministic physics core twice from
# one source with emscripten: the standalone module the wasmtime host runs,
# and the browser/node viewer builds. Wasm output is architecture
# independent, so this stage runs on the build host's native platform
# ($BUILDPLATFORM) -- no qemu emulation for the compile on ARM hosts.
#
# Stage 2 is the linux/amd64 runtime: python:3.12-slim + locked deps via uv,
# with the repo layout preserved at /workspace (the server resolves
# build/*.wasm and viewer/dist relative to the repo root, so the project is
# NOT pip-installed into site-packages).
#
# Entrypoints (Coworld manifest `run`):
#   game    /bin/cogball          -> python -m cogball.server
#   player  /bin/cogball-player   -> python -m players.cogball_player
#
# Build: docker build --platform=linux/amd64 -t coworld-cogball:latest .

FROM --platform=$BUILDPLATFORM emscripten/emsdk:6.0.5 AS wasm-builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl libdigest-sha-perl unzip && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Prefetch the raylib web build into the exact cache location
# sim/build_viewer.sh expects, as its own layer so source edits never
# re-download. URL/sha MUST stay in sync with sim/build_viewer.sh; if they
# drift, build_viewer.sh just re-fetches (correct, slower).
ARG RAYLIB_ZIP_URL="https://github.com/raysan5/raylib/releases/download/5.5/raylib-5.5_webassembly.zip"
ARG RAYLIB_ZIP_SHA256="798b6bea650e78a60fe49f106a15d92ea4e33efd3aa1b3efa34b0438a14bbf2c"
RUN mkdir -p build && \
    curl -fsSL --retry 3 "$RAYLIB_ZIP_URL" -o /tmp/raylib-web.zip && \
    echo "$RAYLIB_ZIP_SHA256  /tmp/raylib-web.zip" | shasum -a 256 -c - && \
    (cd build && unzip -q /tmp/raylib-web.zip && \
     mv raylib-5.5_webassembly raylib-web && \
     printf '%s\n' "$RAYLIB_ZIP_SHA256" > raylib-web/.zip-sha256) && \
    rm /tmp/raylib-web.zip

COPY sim/ sim/
COPY viewer/index.html viewer/index.html
COPY viewer/static_replay.js viewer/static_replay.js

# build_sim.sh first: build_viewer.sh embeds the sha of build/cogball_sim.wasm
# into viewer/dist/sim_sha.js so the viewer can warn about a mismatched replay.
RUN bash sim/build_sim.sh && bash sim/build_viewer.sh


FROM python:3.12-slim

WORKDIR /workspace

# Locked runtime deps only (aiohttp/wasmtime): the project itself stays at
# /workspace via PYTHONPATH so repo-root-relative wasm/viewer paths keep
# working. uv is bind-mounted from its distribution image for this RUN only
# -- a COPY'd binary would persist in its layer even after a later `rm`.
COPY pyproject.toml uv.lock README.md ./
RUN --mount=from=ghcr.io/astral-sh/uv:0.9.18,source=/uv,target=/usr/local/bin/uv \
    uv sync --frozen --no-dev --no-install-project

ENV PATH="/workspace/.venv/bin:$PATH" \
    PYTHONPATH="/workspace/server:/workspace" \
    PYTHONUNBUFFERED=1

COPY server/ server/
COPY players/ players/
COPY --from=wasm-builder /src/build/cogball_sim.wasm build/
COPY --from=wasm-builder /src/viewer/dist/ viewer/dist/

# One-line role shims so the manifest and tools/ci/policies.json can use
# stable /bin entrypoints instead of module paths.
RUN printf '#!/bin/sh\nexec python -m cogball.server "$@"\n' > /bin/cogball && \
    printf '#!/bin/sh\nexec python -m players.cogball_player "$@"\n' \
        > /bin/cogball-player && \
    chmod +x /bin/cogball /bin/cogball-player

CMD ["/bin/cogball"]
