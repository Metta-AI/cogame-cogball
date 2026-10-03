## Private retained replay -> anonymous public replay, using the existing codec.
## Refuse export unless every public state and recorded hash stays identical.
import std/[json, os]
import cogball/[sim, replays, replay_runtime]
import snapshot

let original = parseReplayBytes(readFile(paramStr(1)))
var config = defaultGameConfig()
config.update(original.configJson)
let source = parseJson(config.configJson())
var publicConfig = newJObject()
for key in ["seed", "speed", "num_agents", "minPlayers", "startWaitTicks",
    "lobbyJoinTimeoutTicks", "gameOverTicks", "maxTicks", "maxGames",
    "turnTicks", "mercyGoalDiff", "stalemateTicks", "fastMode",
    "closedRoster", "kickImpulse", "robotMaxSpeed", "ballMaxSpeed"]:
  publicConfig[key] = source[key]
publicConfig["slots"] = newJArray()
for slot in config.slots:
  publicConfig["slots"].add(%*{"team":ord(slot.team)})
var writer = openReplayWriter(paramStr(2), $publicConfig)
for join in original.joins:
  writer.writeJoin(join.time, int(join.player), "seat-" & $join.player, join.slot, "")
for leave in original.leaves:
  writer.writeLeave(leave.time, int(leave.player))
for input in original.inputs: writer.writeInput(input)
for hash in original.hashes: writer.writeHash(hash.tick, hash.hash)
writer.closeReplayWriter()
let publicData = parseReplayBytes(readFile(paramStr(2)))
doAssert publicData.chats.len == 0 and publicData.debugSprites.len == 0 and
  publicData.clientInputs.len == 0
for join in publicData.joins: doAssert join.token.len == 0
var a = initReplayRuntime(original, true, false)
var b = initReplayRuntime(publicData, true, false)
a.sim = initSimServer(a.config); a.sim.gameEventLoggingEnabled = false
a.player = initReplayPlayer(original); a.player.mismatchQuit = true
b.sim = initSimServer(b.config); b.sim.gameEventLoggingEnabled = false
b.player = initReplayPlayer(publicData); b.player.mismatchQuit = true
var compared = 0
while true:
  doAssert proofJson(a.sim) == proofJson(b.sim)
  inc compared
  if a.sim.tickCount >= a.player.replayMaxTick(): break
  a.player.stepReplay(a.sim); b.player.stepReplay(b.sim)
echo $(%*{"statesCompared":compared,"chatsExported":publicData.chats.len,
  "inputs":publicData.inputs.len,"hashes":publicData.hashes.len,
  "originalChats":original.chats.len,"publicConfigKeys":publicConfig.len})
