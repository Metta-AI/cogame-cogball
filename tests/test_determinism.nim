## THE DETERMINISM GATE. If this fails, the physics or a build flag changed —
## fix the code, never the test.
##
## Six halves live here; the seventh — the cross-BUILD half — runs in the
## `wasm-viewer` CI job, where `node tools/wasm_replay_smoke.cjs` re-simulates
## the same fixture through the emscripten wasm32 build and fails if
## `cogball_mismatch_tick() != -1`. That is the only place a wasm32 32-bit
## `int` overflow can be caught, because `int` is 64 bits here.

import std/[json, math, os, random, strutils, tables]
import lib/helpers
import cogball/trig

const GoldenPath = "tests/data/golden_hashes.json"

proc sameSeedSameLog() =
  ## (a) Same seed + same mask log => identical gameHash at every tick, run
  ## twice in one process and once in a fresh sim.
  let config = testConfig(maxTicks = DefaultMaxTicks)
  let recorded = runScriptedMatch(config, "formation", "swarm",
    collectMasks = true)
  doAssert recorded.masks.len > 1000, "the recording is too short to prove much"

  proc replay(masks: seq[array[RobotCount, uint8]]): seq[uint64] =
    var sim = seatedSim(config)
    for tick in 0 ..< masks.len:
      sim.stepWith(masks[tick])
      result.add(sim.gameHash())

  let first = replay(recorded.masks)
  let second = replay(recorded.masks)
  doAssert first == second, "two runs in one process disagreed"
  var fresh = seatedSim(config)
  for tick in 0 ..< recorded.masks.len:
    fresh.stepWith(recorded.masks[tick])
    doAssert fresh.gameHash() == first[tick],
      "a fresh sim diverged at tick " & $tick
  doAssert fresh.goals(Azure) == recorded.goals[Azure]
  doAssert fresh.goals(Crimson) == recorded.goals[Crimson]
  report "the same seed and mask log reproduce every tick's hash"

proc oneBitMatters() =
  ## (b) A one-bit change in any recorded mask changes the final hash. The bit
  ## is CLEARED where the control layer actually set it, so the flip is one the
  ## sim was going to act on — setting a bit whose preconditions are unmet is
  ## legitimately a no-op and would prove nothing.
  let config = testConfig(maxTicks = 1200)
  let recorded = runScriptedMatch(config, "formation", "swarm",
    collectMasks = true)
  proc finalHash(masks: seq[array[RobotCount, uint8]]): uint64 =
    var sim = seatedSim(config)
    for tick in 0 ..< masks.len:
      sim.stepWith(masks[tick])
    sim.gameHash()
  let base = finalHash(recorded.masks)
  var proven = 0
  for bit in [ButtonUp, ButtonDown, ButtonLeft, ButtonRight, ButtonSelect,
              ButtonA]:
    var moved = false
    for robot in 0 ..< RobotCount:
      var at = -1
      for tick in 0 ..< recorded.masks.len:
        let mask = recorded.masks[tick][robot]
        if (mask and bit) == 0:
          continue
        # A thrust bit under a held brake is a legitimate no-op (the sim forces
        # uThrust to zero), so it proves nothing about the hash.
        if bit in [ButtonUp, ButtonDown] and (mask and ButtonSelect) != 0:
          continue
        at = tick
        break
      if at < 0:
        continue
      var masks = recorded.masks
      masks[at][robot] = masks[at][robot] and not bit
      if finalHash(masks) != base:
        moved = true
        break
    doAssert moved,
      "clearing bit " & $bit & " never moved the final hash on any robot"
    inc proven
  doAssert proven == 6, "only " & $proven & " mask bits were proven"
  report "a one-bit change in the action log changes the final hash"

proc goldenHashes() =
  ## (c) A committed golden fixture pins the hash at every 100th tick for seed
  ## 679961, so any physics change is visible in the diff rather than silent.
  let config = testConfig(maxTicks = 2400)
  let recorded = runScriptedMatch(config, "formation", "swarm",
    collectMasks = true)
  var sim = seatedSim(config)
  var observed = newJObject()
  for tick in 0 ..< recorded.masks.len:
    sim.stepWith(recorded.masks[tick])
    if sim.tickCount mod 100 == 0:
      observed[$sim.tickCount] = %($sim.gameHash())
  doAssert observed.len >= 10, "not enough sample points"
  if not fileExists(GoldenPath) or getEnv("COGBALL_WRITE_GOLDEN").len > 0:
    createDir(GoldenPath.parentDir())
    writeFile(GoldenPath, pretty(%*{
      "note": "gameHash at every 100th tick of a formation-vs-swarm match at " &
        "seed 679961, maxTicks 2400. Regenerate with COGBALL_WRITE_GOLDEN=1.",
      "seed": config.seed,
      "maxTicks": config.maxTicks,
      "gameVersion": GameVersion,
      "hashes": observed
    }) & "\n")
    echo "  ..  wrote ", GoldenPath
    return
  let golden = parseJson(readFile(GoldenPath))
  doAssert golden{"gameVersion"}.getStr() == GameVersion,
    "the golden fixture was recorded under GameVersion " &
      golden{"gameVersion"}.getStr() & "; re-record it with the bump"
  let want = golden["hashes"]
  doAssert want.len == observed.len,
    "the golden fixture has " & $want.len & " points, this run has " &
      $observed.len
  for key, value in want:
    doAssert observed.hasKey(key), "tick " & key & " is missing from this run"
    doAssert observed[key].getStr() == value.getStr(),
      "gameHash diverged from the golden fixture at tick " & key &
        ": " & observed[key].getStr() & " != " & value.getStr()
  report "every hundredth tick matches the committed golden fixture"

const GuardedSources = [
  "src/cogball/sim.nim",
  "src/cogball/sim_types.nim",
  "src/cogball/sim_config.nim",
  "src/cogball/sim_state.nim",
  "src/cogball/pitch.nim",
  "src/cogball/control.nim",
  "src/cogball/trig.nim"
]

const BannedIdentifiers = [
  "sin", "cos", "tan", "arctan", "arcsin", "arccos", "arctan2",
  "exp", "ln", "log2", "log10", "pow", "sqrt", "hypot",
  "float", "float32", "float64", "cfloat", "cdouble"
]

proc sourceGuard() =
  ## (d) No floating point and no libm in the sim's own modules. Comments and
  ## string literals are stripped first, so this greps IDENTIFIERS — prose
  ## about "floating point" is fine, a call to `sqrt` is not.
  var banned: Table[string, bool]
  for name in BannedIdentifiers:
    banned[name] = true
  for path in GuardedSources:
    doAssert fileExists(path), "guarded source is missing: " & path
    let code = sourceText(path)
    for ident in identifiers(code):
      doAssert not banned.hasKey(ident),
        "banned identifier `" & ident & "` in " & path &
          " — the sim must stay integer-only (docs/RULES.md §Determinism)"
    doAssert "std/math" notin code,
      "`std/math` is imported by " & path
  # And no fast-math anywhere in the build scripts.
  for path in ["Dockerfile", "Dockerfile.replay-viewer",
               "replay-viewer/config.nims", ".github/workflows/ci.yml"]:
    doAssert "-ffast-math" notin readFile(path),
      "-ffast-math in " & path
  report "the sim modules are float-free and libm-free"

proc trigTable() =
  ## (e) SinQ12 re-derived from math.sin entry by entry, and isqrt checked
  ## exhaustively below 2^16 and on perfect squares to 2^40.
  for b in 0 ..< 256:
    let want = int32(round(4096.0 * sin(2.0 * PI * float(b) / 256.0)))
    doAssert SinQ12[b] == want,
      "SinQ12[" & $b & "] is " & $SinQ12[b] & ", math.sin says " & $want
  doAssert cosQ12(0) == 4096
  doAssert sinQ12(64) == 4096
  for v in 0 ..< 65536:
    let r = isqrt(int64(v))
    doAssert r * r <= int64(v) and (r + 1) * (r + 1) > int64(v),
      "isqrt(" & $v & ") = " & $r
  var n = 1'i64
  while n * n <= (1'i64 shl 40):
    doAssert isqrt(n * n) == n, "isqrt of a perfect square failed at " & $n
    doAssert isqrt(n * n - 1) == n - 1
    n = n * 3 div 2 + 1
  report "SinQ12 re-derives from math.sin and isqrt is exact"

proc atan2Agreement() =
  ## (f) bradsOfVectorI agrees with a float arctan2 reference to +-1 brad over
  ## 100 000 pseudo-random vectors, and is EXACTLY antisymmetric under
  ## (dx, dy) -> (dx, -dy).
  var rng = initRand(0x0C06BA11)
  var worst = 0
  for _ in 0 ..< 100_000:
    let
      dx = int32(rng.rand(2 * int(WorldW)) - int(WorldW))
      dy = int32(rng.rand(2 * int(WorldH)) - int(WorldH))
    if dx == 0 and dy == 0:
      continue
    let got = bradsOfVectorI(dx, dy)
    let want = ((int(round(arctan2(-float(dy), float(dx)) * 128.0 / PI)) mod
      256) + 256) mod 256
    var delta = abs(int(got) - want)
    if delta > 128:
      delta = 256 - delta
    doAssert delta <= 1,
      "bradsOfVectorI(" & $dx & "," & $dy & ") = " & $got &
        ", arctan2 says " & $want
    worst = max(worst, delta)
    doAssert int(bradsOfVectorI(dx, -dy)) == (256 - int(got)) mod 256,
      "not antisymmetric at (" & $dx & "," & $dy & ")"
  report "bradsOfVectorI matches arctan2 to +-" & $worst &
    " brad and is exactly antisymmetric"

proc hashExcludesDirectives() =
  ## Nothing a coach says can move the hash chain: the directive is presentation
  ## state, and so are the trail, the paint and the feed.
  var a = playing(testConfig())
  var b = playing(testConfig())
  let before = a.gameHash()
  a.activeDirective[Azure].note = "a note that must not matter"
  a.activeDirective[Azure].robots[0].intent = inPress
  a.activeDirective[Azure].robots[0].say = "nor this"
  a.hasDirective[Azure] = true
  a.feed.add FeedLine(tick: 1, kind: "note", seat: 0, text: "loud")
  a.trail.add TrailPoint(x: 1, y: 2, tick: 3, seat: 0)
  a.paint.add PaintDot(x: 1, y: 2, robot: 0)
  a.kickFx.add KickFx(x: 1, y: 2, tick: 3, seat: 0)
  doAssert a.gameHash() == before, "presentation state entered the hash"
  doAssert a.gameHash() == b.gameHash()
  report "directives, feed, trail, paint and FX stay out of gameHash"

when isMainModule:
  echo "test_determinism"
  sourceGuard()
  trigTable()
  atan2Agreement()
  hashExcludesDirectives()
  sameSeedSameLog()
  oneBitMatters()
  goldenHashes()
  echo "test_determinism: all good"
