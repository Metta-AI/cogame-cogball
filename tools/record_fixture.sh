#!/bin/bash
# Records one cogball episode as a .bitreplay fixture, with the NATIVE build.
#
# The wasm smoke exists to catch a divergence between two builds of the SAME
# source, so the fixture must come from the same commit: CI records it in the
# test job and hands it to the wasm-viewer job as an artifact.
# Usage: tools/record_fixture.sh <out.bitreplay> <seed> [maxTicks] [extraConfigJson]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; SEED="$2"; MAXTICKS="${3:-10000}"; EXTRA="${4:-}"; PORT="${PORT:-21000}"
[ -z "$EXTRA" ] && EXTRA='{}'
CFG=$(mktemp /tmp/cogball-fixture-cfg-$$-XXXXXX)
python3 - "$CFG" "$SEED" "$MAXTICKS" "$EXTRA" <<'PY'
import json, sys
cfg = json.load(open("config.json"))
cfg["seed"] = int(sys.argv[2])
cfg["maxTicks"] = int(sys.argv[3])
cfg["maxGames"] = 1
cfg.update(json.loads(sys.argv[4]))
json.dump(cfg, open(sys.argv[1], "w"))
PY
LOG="${LOG:-/tmp/cogball-fixture-server-$$.log}"
COGAME_HOST=127.0.0.1 COGAME_PORT=$PORT \
COGAME_CONFIG_URI="file://$CFG" \
COGAME_SAVE_REPLAY_URI="file://$PWD/$OUT" \
./bin/cogball > "$LOG" 2>&1 &
SERVER_PID=$!

# Wait for the port to actually listen before spawning bots — a slow start
# would otherwise strand the bots and hang the lobby forever, silently.
for i in $(seq 1 40); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "server died during startup; log tail:" >&2
    tail -20 "$LOG" >&2
    exit 1
  fi
  sleep 0.5
done
nc -z 127.0.0.1 "$PORT" || { echo "server never listened" >&2; tail -20 "$LOG" >&2; exit 1; }

BOT_PIDS=()
for i in ${SLOTS:-$(seq 0 1)}; do
  PLAYER_SCRIPTED="${PLAYER_SCRIPTED:-formation}" \
  COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$PORT/player?slot=$i&token=0xBADA55_$i" \
    ./bin/cogball-player >/dev/null 2>&1 &
  BOT_PIDS+=($!)
done

# Bounded wait: with both seats scripted and fastMode on, even a full-length
# episode finishes in seconds; anything longer is a hang, and hangs must be
# loud, not silent.
DEADLINE=$((SECONDS + 600))
while kill -0 $SERVER_PID 2>/dev/null; do
  if [ $SECONDS -ge $DEADLINE ]; then
    echo "server still running after 10 minutes — killing; log tail:" >&2
    tail -20 "$LOG" >&2
    kill $SERVER_PID 2>/dev/null || true
    for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    exit 1
  fi
  sleep 2
done
wait $SERVER_PID || { echo "server exited non-zero; log tail:" >&2; tail -20 "$LOG" >&2; }
for p in "${BOT_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
rm -f "$CFG"
# A written replay under ~10KB is a truncated episode, not a fixture.
SIZE=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null || echo 0)
if [ "$SIZE" -lt 10000 ]; then
  echo "replay missing or truncated ($SIZE bytes); server log tail:" >&2
  tail -20 "$LOG" >&2
  exit 1
fi
ls -la "$OUT"
