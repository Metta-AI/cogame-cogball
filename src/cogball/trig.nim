## Integer trigonometry: the committed sine table, the integer square root and
## the integer atan2. This module is the whole reason the physics core can be
## float-free.
##
## Nim's `int` is 64-bit natively and 32-bit under `--cpu:wasm32`, and the same
## sim compiles both ways, so every product here is taken in `int64` and
## narrowed with an explicit truncating `div`. Nim's `div` truncates toward
## zero, so the arithmetic is symmetric under negation — which is what makes
## the two ends of the pitch exactly fair.
##
## `SinQ12` is a COMMITTED literal table, generated once by
## `tools/gen_trig_table.nim` and checked in. A compile-time `const` computed
## from `sin()` was rejected: the native amd64 server and the emscripten wasm32
## viewer are two separate compilations, and a committed table removes the
## question of whether their libm agrees. `tests/test_determinism.nim`
## re-derives every entry from `math.sin`, so the table can never drift.
##
## NOTE: no `import std/math` here, and none anywhere under
## `src/cogball/{sim,sim_types,sim_config,sim_state,pitch,control,trig}.nim` —
## the source guard in tests/test_determinism.nim greps for it.

const
  SinQ12*: array[256, int32] = [
  0, 101, 201, 301, 401, 501, 601, 700, 799, 897, 995, 1092, 1189, 1285,
  1380, 1474, 1567, 1660, 1751, 1842, 1931, 2019, 2106, 2191, 2276, 2359,
  2440, 2520, 2598, 2675, 2751, 2824, 2896, 2967, 3035, 3102, 3166, 3229,
  3290, 3349, 3406, 3461, 3513, 3564, 3612, 3659, 3703, 3745, 3784, 3822,
  3857, 3889, 3920, 3948, 3973, 3996, 4017, 4036, 4052, 4065, 4076, 4085,
  4091, 4095, 4096, 4095, 4091, 4085, 4076, 4065, 4052, 4036, 4017, 3996,
  3973, 3948, 3920, 3889, 3857, 3822, 3784, 3745, 3703, 3659, 3612, 3564,
  3513, 3461, 3406, 3349, 3290, 3229, 3166, 3102, 3035, 2967, 2896, 2824,
  2751, 2675, 2598, 2520, 2440, 2359, 2276, 2191, 2106, 2019, 1931, 1842,
  1751, 1660, 1567, 1474, 1380, 1285, 1189, 1092, 995, 897, 799, 700, 601,
  501, 401, 301, 201, 101, 0, -101, -201, -301, -401, -501, -601, -700,
  -799, -897, -995, -1092, -1189, -1285, -1380, -1474, -1567, -1660,
  -1751, -1842, -1931, -2019, -2106, -2191, -2276, -2359, -2440, -2520,
  -2598, -2675, -2751, -2824, -2896, -2967, -3035, -3102, -3166, -3229,
  -3290, -3349, -3406, -3461, -3513, -3564, -3612, -3659, -3703, -3745,
  -3784, -3822, -3857, -3889, -3920, -3948, -3973, -3996, -4017, -4036,
  -4052, -4065, -4076, -4085, -4091, -4095, -4096, -4095, -4091, -4085,
  -4076, -4065, -4052, -4036, -4017, -3996, -3973, -3948, -3920, -3889,
  -3857, -3822, -3784, -3745, -3703, -3659, -3612, -3564, -3513, -3461,
  -3406, -3349, -3290, -3229, -3166, -3102, -3035, -2967, -2896, -2824,
  -2751, -2675, -2598, -2520, -2440, -2359, -2276, -2191, -2106, -2019,
  -1931, -1842, -1751, -1660, -1567, -1474, -1380, -1285, -1189, -1092,
  -995, -897, -799, -700, -601, -501, -401, -301, -201, -101
  ]
    ## SinQ12[b] = round(4096 * sin(2*PI*b/256)).

proc cosQ12*(brads: int32): int32 {.inline.} =
  ## cos in Q12 for a brad angle; cos(x) = sin(x + 90 degrees).
  SinQ12[int((brads + 64) and 255)]

proc sinQ12*(brads: int32): int32 {.inline.} =
  SinQ12[int(brads and 255)]

proc isqrt*(value: int64): int64 =
  ## Floor of the square root, by Newton's method from a bit-length seed. The
  ## ONLY square root in the sim, and the only place a length is taken.
  if value <= 0:
    return 0
  if value < 4:
    return 1
  # Seed at 2^(ceil(bits/2)) so the iteration converges from above in a few
  # steps for every magnitude the sim can reach (positions square to ~2e15).
  var bits = 0
  var probe = value
  while probe > 0:
    probe = probe shr 1
    inc bits
  var guess = 1'i64 shl ((bits + 1) div 2)
  while true:
    let next = (guess + value div guess) div 2
    if next >= guess:
      break
    guess = next
  while guess * guess > value:
    dec guess
  while (guess + 1) * (guess + 1) <= value:
    inc guess
  guess

proc distI*(dx, dy: int32): int32 {.inline.} =
  ## Euclidean length of a world-space delta, in micrometres.
  int32(isqrt(int64(dx) * int64(dx) + int64(dy) * int64(dy)))

proc bradsOfVectorI*(dx, dy: int32): int32 =
  ## The integer atan2: the brad angle of a map-space vector, 0 = east (+x),
  ## increasing counter-clockwise ON SCREEN (screen y points down, so 64 is
  ## north = -y). This is the exact integer twin of ctf's float
  ## `bradsOfVector`, and there is no `arctan2` anywhere in the sim.
  ##
  ## Folds (u, v) = (dx, -dy) into the first octant by sign and swap, binary
  ## searches brads 0..32 on the exact cross-product comparison
  ## `SinQ12[m]*u <= v*cosQ12(m)` (both sides in int64), picks the nearer of
  ## the two bracketing steps, then unfolds. Because the fold happens BEFORE
  ## the search, the result is exactly antisymmetric under (dx, dy) ->
  ## (dx, -dy).
  if dx == 0 and dy == 0:
    return 0
  var
    u = int64(dx)
    v = -int64(dy)
    negate = false
    reflect = false
    swapped = false
  if v < 0:
    v = -v
    negate = true
  if u < 0:
    u = -u
    reflect = true
  if v > u:
    swap(u, v)
    swapped = true
  # u >= v >= 0: the angle is in [0, 32] brads.
  var lo = 0'i32
  var hi = 32'i32
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if int64(SinQ12[int(mid)]) * u <= v * int64(cosQ12(mid)):
      lo = mid
    else:
      hi = mid - 1
  var best = lo
  if lo < 32:
    let
      errLo = abs(v * int64(cosQ12(lo)) - int64(SinQ12[int(lo)]) * u)
      errHi = abs(v * int64(cosQ12(lo + 1)) - int64(SinQ12[int(lo + 1)]) * u)
    if errHi < errLo:
      best = lo + 1
  var brads = best
  if swapped:
    brads = 64 - brads
  if reflect:
    brads = 128 - brads
  if negate:
    brads = -brads
  ((brads mod 256) + 256) mod 256
