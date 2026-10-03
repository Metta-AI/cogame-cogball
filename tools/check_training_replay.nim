## Validate private physical evidence against the actual binary replay and hashes.
import std/[base64, json, os, strutils]
import cogball/[replays, sim]

let args = commandLineParams()
doAssert args.len == 2
let data = loadReplay(args[0])
var config = defaultGameConfig()
config.update(data.configJson)
var game = initSimServer(config)
game.gameEventLoggingEnabled = false
var replay = initReplayPlayer(data)
replay.mismatchQuit = true
var
  executions: seq[JsonNode]
  masks: seq[string]
  checked: seq[int]
for line in lines(args[1]):
  let event = parseJson(line)
  if event["event_type"].getStr() == "decision":
    executions.add(%*{"seat": event["seat"], "physical": event["observation"]["execution"]})
    masks.add(decode(event["observation"]["execution"]["seat_input_masks_b64"].getStr()))
    checked.add(0)
while replay.hashIndex < data.hashes.len:
  let tick = game.tickCount
  let initialHash = game.gameHash()
  replay.stepReplay(game)
  for index, row in executions:
    let physical = row["physical"]
    let first = physical["start_tick"].getInt()
    let last = physical["end_tick"].getInt()
    if tick >= first and tick < last:
      if tick == first: doAssert $initialHash == physical["initial_hash"].getStr()
      let offset = tick - first
      doAssert $game.gameHash() == physical["post_tick_hashes"][offset].getStr()
      let seat = parseInt(row["seat"].getStr())
      for slot in 0 ..< RobotsPerSeat:
        doAssert uint8(masks[index][offset * RobotsPerSeat + slot]) ==
          replay.lastAppliedMasks[seat * RobotsPerSeat + slot]
      inc checked[index]
for index, row in executions:
  let physical = row["physical"]
  doAssert checked[index] == physical["end_tick"].getInt() - physical["start_tick"].getInt()
echo "validated ", game.tickCount, " replay ticks and ", executions.len, " private macros"
