#!/usr/bin/env bash
# Grid harness for the scripted baselines' tuning constants.
#
# baselines.nim's constants are `{.intdefine.}` so they can be driven from the
# command line; this is the loop that varies ONE of them at a time, rebuilds,
# and plays the whole seed list both sides. `tools/tune_baselines.nim` is the
# runner (see its docstring for what one row measures);
# `docs/tuning/baseline-grid.md` records what the sweeps found.
#
#   tools/tune_baselines.sh CogballKeeperArc 1000000 2000000 3000000 4000000
#   TUNE_TICKS=2400 tools/tune_baselines.sh CogballStrikerRange 6000000 9000000
#   tools/tune_baselines.sh                 # just the committed values
#
# env:
#   TUNE_TICKS   maxTicks per match (default 4800, a full 3:20 match)
#   TUNE_SEEDS   space-separated seeds (default: the runner's own 12)
#   NIM          the nim binary (default: nim on PATH)
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"

nim_bin="${NIM:-nim}"
ticks="${TUNE_TICKS:-4800}"
seeds="${TUNE_SEEDS:-}"
out="$(mktemp -d "${TMPDIR:-/tmp}/cogball-tune.XXXXXX")"
trap 'rm -rf "${out}"' EXIT

define="${1:-}"
shift || true

run_one() {
  # $1: the -d: flag to build with, or empty for the committed values.
  local flag="$1"
  local binary="${out}/tune"
  # shellcheck disable=SC2086
  "${nim_bin}" c --hints:off --warnings:off -d:release --path:src \
    ${flag:+-d:${flag}} --out:"${binary}" tools/tune_baselines.nim >/dev/null
  # shellcheck disable=SC2086
  "${binary}" "${ticks}" ${seeds}
}

if [ -z "${define}" ]; then
  echo "== committed values"
  run_one ""
  exit 0
fi

if [ "$#" -eq 0 ]; then
  echo "usage: tools/tune_baselines.sh <CogballDefineName> <value> [value ...]" >&2
  exit 2
fi

echo "== sweeping ${define} over ${ticks}-tick matches"
for value in "$@"; do
  echo "-- ${define}=${value}"
  run_one "${define}=${value}"
done
