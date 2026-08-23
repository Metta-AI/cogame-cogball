## Expands one cogball `.bitreplay` into a readable timeline on stdout: the
## config header, every recorded chat record, and the derived beat events
## (goal, save, shot, drop, kickoff, gameover) with their ticks.
##
## The counterpart to `tools/replay_summary.py`, which needs no Nim; this one
## re-simulates, so it can report anything the sim knows.
##
##   nim r --hints:off -d:release --path:src tools/expand_replay.nim ep.bitreplay

import std/[json, os, strformat, strutils]
import cogball/[broadcast, replays, replay_runtime, roster, sim]

when isMainModule:
  if paramCount() < 1:
    quit("usage: expand_replay <replay.bitreplay> [maxTicks]", 2)
  let data = parseReplayBytes(readFile(paramStr(1)))
  echo &"game {data.gameName} v{data.gameVersion}"
  echo "config: ", data.configJson
  var initialized = initReplayRuntime(
    data, mismatchQuit = false, gameEventLoggingEnabled = false)
  var
    game = initialized.sim
    player = initialized.player
    tracker = initBroadcastTracker()
  # Re-walk from tick zero so the timeline is complete.
  var walker = initReplayPlayer(data)
  game = initSimServer(initialized.config)
  tracker.resync(game)
  let limit =
    if paramCount() >= 2: parseInt(paramStr(2)) else: walker.replayMaxTick()
  while walker.hashIndex < data.hashes.len and game.tickCount < limit:
    walker.stepReplay(game)
    var events = newJArray()
    game.stepEvents(tracker, events)
    for event in events:
      if event["k"].getStr() notin ["touch", "kick"]:
        echo &"""{game.tickCount:>6}  {event["k"].getStr()}  {event}"""
  for chat in data.chats:
    echo &"""chat @{chat.time}ms  {chat.message}"""
  echo "final: ", game.playerResultsJson()
  echo "mismatch tick: ", walker.hashMismatchTick
  discard player
