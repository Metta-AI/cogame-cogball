## Regenerates the committed SinQ12 table in src/cogball/trig.nim.
##
## The table is CHECKED IN on purpose: the native amd64 server and the
## emscripten wasm32 viewer are two separate compilations, and a committed
## table removes any question of whether their libm agrees. Run this only when
## the resolution changes, paste the output over the array literal, and let
## tests/test_determinism.nim re-derive every entry from `math.sin`.
##
##   nim r --hints:off tools/gen_trig_table.nim

import std/[math, strutils]

var parts: seq[string]
for b in 0 ..< 256:
  parts.add($int32(round(4096.0 * sin(2.0 * PI * float(b) / 256.0))))

var line = "  "
var rows: seq[string]
for i, part in parts:
  let piece = part & (if i < parts.high: "," else: "")
  if line.len + piece.len + 1 > 74:
    rows.add(line)
    line = "  "
  if line.len > 2:
    line.add(" ")
  line.add(piece)
rows.add(line)
echo "  SinQ12*: array[256, int32] = ["
echo rows.join("\n")
echo "  ]"
