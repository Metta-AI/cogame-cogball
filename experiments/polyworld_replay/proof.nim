## Consume the committed codec/masks; never run coaching or record episodes.
import std/[json, os, tables, strutils]
import flatty
import cogball/[sim, replays, replay_runtime]
import snapshot

let data = parseReplayBytes(readFile(paramStr(1)))
var r = initReplayRuntime(data, true, false)
# Include the lobby in the cross-target trace, not just the automatic spectator
# opening tick. Use the original config, codec and stepReplay for every tick.
r.sim = initSimServer(r.config)
r.sim.gameEventLoggingEnabled = false
r.player = initReplayPlayer(data)
r.player.mismatchQuit = true
var states = initTable[int, JsonNode]()
var goals: seq[int]
var lastScore: array[2,int32]
let output = open(paramStr(2), fmWrite)
while true:
  let before = toFlatty(r.sim)
  let view = snapshot(r.sim)
  for i in 0..3: discard view.publicJson()
  doAssert toFlatty(r.sim) == before
  let node = proofJson(r.sim)
  states[r.sim.tickCount] = node
  output.writeLine($node)
  if view.score != lastScore:
    goals.add(r.sim.tickCount)
    lastScore = view.score
  if r.sim.tickCount >= r.player.replayMaxTick(): break
  r.player.stepReplay(r.sim)
output.close()
doAssert not r.player.hashValidationFailed
doAssert goals.len > 0, "retained fixture must contain a goal"
var seekTargets = @[r.player.replayStartTick(), r.player.replayMaxTick()]
for tick in goals:
  for target in [tick-1,tick,tick+1,tick+int(KickoffFreezeTicks)]:
    if states.hasKey(target): seekTargets.add(target)
for target in seekTargets:
  r.player.seekReplay(r.sim,target)
  doAssert proofJson(r.sim) == states[target]
var privateState = r.sim
privateState.activeDirective[Azure].note = "PRIVATE_COACH_SENTINEL"
privateState.activeDirective[Crimson].robots[0].say = "PRIVATE_PROVIDER_SENTINEL"
privateState.config.model = "PRIVATE_TRAINING_SENTINEL"
doAssert snapshot(privateState).publicJson() == snapshot(r.sim).publicJson()
doAssert "PRIVATE_" notin $snapshot(privateState).publicJson()
# Authored mismatch in memory; never save it as a match or update a golden.
var corrupted = data
corrupted.hashes = @[]
for hash in data.hashes: corrupted.hashes.add(hash)
corrupted.hashes[0].hash = corrupted.hashes[0].hash xor 1'u64
var rejected = false
try: discard initReplayRuntime(corrupted,true,false)
except ReplayError as error:
  doAssert ("mismatch at tick " & $corrupted.hashes[0].tick) in error.msg
  rejected = true
doAssert rejected
writeFile(paramStr(3), $(%*{"ticks":states.len,"goals":goals,
  "seeks":seekTargets,"finalScore":lastScore,"hashMismatch":r.player.hashMismatchTick,
  "privateSentinelsExcluded":true,"corruptedHashRejected":true}))
