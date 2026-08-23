## Re-simulates one cogball `.bitreplay` and writes the tier-2 JSON-lines
## analysis stream — byte-identical to what a live server writes to
## `COGAME_EVENTS_URI`, because both go through `events.eventsJsonl`.
##
##   nim r --hints:off -d:release --path:src tools/extract_events.nim ep.bitreplay out.jsonl

import std/[json, os]
import cogball/[events, replay_runtime, replays, roster, sim]

when isMainModule:
  if paramCount() < 1:
    quit("usage: extract_events <replay.bitreplay> [out.jsonl]", 2)
  let data = parseReplayBytes(readFile(paramStr(1)))
  var initialized = initReplayRuntime(
    data, mismatchQuit = false, gameEventLoggingEnabled = false)
  var game = initSimServer(initialized.config)
  game.collectEvents = true
  var walker = initReplayPlayer(data)
  var collected: seq[SimEvent]
  while walker.hashIndex < data.hashes.len and
      game.tickCount < walker.replayMaxTick():
    walker.stepReplay(game)
    for event in game.events:
      collected.add(event)
    game.events.setLen(0)
  var summary = newJObject()
  summary["seed"] = %initialized.config.seed
  summary["results"] = parseJson(game.playerResultsJson())
  summary["mismatchTick"] = %walker.hashMismatchTick
  let text = collected.eventsJsonl(game.tickCount, summary)
  if paramCount() >= 2:
    writeFile(paramStr(2), text)
    echo "wrote ", paramStr(2), " (", collected.len, " events)"
  else:
    stdout.write(text)
