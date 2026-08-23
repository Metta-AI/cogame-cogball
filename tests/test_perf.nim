## Release-only: 4800 ticks of physics plus mask compilation complete well
## inside the frame budget. The design's bound is 120 s; the target is 30 s on
## a CI runner, and a real regression here means the hosted episode will not
## finish inside `wallClockBudgetSeconds`.

import std/[times, strformat]
import lib/helpers

proc fullMatchIsFast() =
  let started = epochTime()
  let result = runScriptedMatch(testConfig(seed = 679961), "formation", "swarm")
  let elapsed = epochTime() - started
  doAssert result.ticks >= DefaultMaxTicks,
    "the match ended early at " & $result.ticks & " ticks"
  echo &"  ..  4800 ticks in {elapsed:.2f} s ({result.goals[Azure]}-" &
    &"{result.goals[Crimson]})"
  doAssert elapsed < 120.0,
    &"a full match took {elapsed:.1f} s against the 120 s bound"
  report "a full 4800-tick match simulates inside the bound"

proc replayScanIsFast() =
  ## The whole-match precompute walk is what the hosted viewer pays before the
  ## momentum graph and the beat markers can ship.
  let started = epochTime()
  let recorded = runScriptedMatch(testConfig(seed = 7919, maxTicks = 2400),
    "formation", "formation", collectMasks = true)
  var sim = seatedSim(testConfig(seed = 7919, maxTicks = 2400))
  for masks in recorded.masks:
    sim.stepWith(masks)
    discard sim.gameHash()
  let elapsed = epochTime() - started
  echo &"  ..  a 2400-tick re-simulation with hashing in {elapsed:.2f} s"
  doAssert elapsed < 60.0,
    &"re-simulation took {elapsed:.1f} s"
  report "re-simulating a match with a hash per tick is inside the bound"

when isMainModule:
  echo "test_perf"
  fullMatchIsFast()
  replayScanIsFast()
  echo "test_perf: all good"
