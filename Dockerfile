# Build Docker. Two binaries out of ONE image, selected by entrypoint:
# /bin/cogball is the game server, /bin/cogball-player is every policy.
FROM debian:bookworm-slim AS build
SHELL ["/usr/bin/nice", "-n", "19", "/bin/sh", "-c"]

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/cogball
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
# The committed nim.cfg (if any) pins the AUTHOR's package paths; rebuild it
# from THIS container's package tree, exactly as CI does.
RUN rm -f nim.cfg && \
  for pkg in /root/.nimby/pkgs/*; do \
    if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg; \
    else echo "--path:\"$pkg\"" >> nim.cfg; fi; \
  done && \
  echo '--path:"src"' >> nim.cfg && cat nim.cfg

ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on --threads:on --mm:orc"
RUN nim c --parallelBuild:1 $NimFlags --nimcache:/tmp/cogball-nimcache --out:cogball src/cogball.nim && \
    nim c --parallelBuild:1 $NimFlags --nimcache:/tmp/cogball-player-nimcache \
      --out:cogball-player src/cogball_player.nim

# Run Docker.
FROM debian:bookworm-slim
SHELL ["/usr/bin/nice", "-n", "19", "/bin/sh", "-c"]

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/cogball
COPY --from=build /workspace/cogball/cogball /bin/cogball
COPY --from=build /workspace/cogball/cogball-player /bin/cogball-player
COPY --from=build /workspace/cogball/*.json ./
COPY --from=build /workspace/cogball/data ./data
COPY --from=build /workspace/cogball/client ./client
# Public runtime assets must remain readable when the build checkout is private.
RUN find data client -type d -exec chmod 755 {} + && \
    find data client -type f -exec chmod 644 {} + && \
    chmod 644 ./*.json

CMD ["/bin/cogball"]
