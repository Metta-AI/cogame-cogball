## An end-to-end episode that WRITES a replay, then reads it back through
## every path a spectator or a forensic reader would use: `parseReplayBytes`,
## the re-simulation and its hash chain, and `tools/replay_summary.py` under a
## STRICT UTF-8 JSON parser.

import std/[json, os, osproc, strutils, unicode]
import lib/helpers
import cogball/[broadcast, replays, replay_runtime]

const
  NonAsciiSay = "vamos \u26BD\u{1F3C6}"        ## a 4-byte emoji in a `say`
  NonAsciiLabel = "\u00e9quipe \u00e9clair"    ## a non-ASCII policy label

proc recordEpisode(path: string): tuple[hashes: seq[uint64], sim: SimServer] =
  ## Runs a full scripted-vs-scripted episode through the SAME code path the
  ## server uses — the control layer, the record fold-back and the writer —
  ## and forces a non-ASCII `say` and policy label into the stream so the
  ## UTF-8 path is real rather than theoretical.
  let config = testConfig(seed = 679961, maxTicks = 1200)
  var sim = seatedSim(config)
  var writer = openReplayWriter(path, config.configJson())
  writer.lastMasks = newSeq[uint8](RobotCount)
  defer: writer.closeReplayWriter()

  proc emit(sim: var SimServer, writer: var ReplayWriter, text: string) =
    writer.writeChat(tickTime(sim.tickCount), 0, capRecord(text))
    sim.applyRecord(capRecord(text))

  for i, player in sim.players:
    writer.writeJoin(tickTime(sim.tickCount), i, player.address, i, "t" & $i)
  for seat in Seat:
    sim.emit(writer, $(%*{
      "k": "register", "seat": ord(seat), "alias": seatAlias(seat),
      "policy": clipRunes(NonAsciiLabel, MaxPolicyRunes),
      "kind": "scripted", "baseline": "formation"}))

  var prev = newSeq[InputState](RobotCount)
  var guard = 0
  while sim.phase != GameOver and guard < 6000:
    inc guard
    if sim.phase == Playing:
      let elapsed = sim.tickCount - sim.gameStartTick
      if elapsed mod sim.turnTicks() == 0 or
          not (sim.hasDirective[Azure] and sim.hasDirective[Crimson]):
        let turn = elapsed div sim.turnTicks()
        for seat in Seat:
          var directive = sim.baselineDirective(
            seat, (if seat == Azure: "formation" else: "swarm"), turn)
          directive.robots[0].say = clipRunes(NonAsciiSay, MaxSayRunes)
          # Two hand-planted attempt records, so the summary's `fallbacks`
          # count has something to be wrong about: turn 1 fails attempt 1 and
          # then SUCCEEDS on the retry (source stays "llm" -- that turn did not
          # fall back), turn 2 fails both attempts and plays the scripted
          # fallback. A count of `fallback` RECORDS would report two fallen-back
          # turns where there was one.
          if seat == Azure and turn == 1:
            directive.source = dsLlm
            sim.emit(writer, $(%*{
              "k": "fallback", "turn": turn, "seat": ord(seat),
              "attempt": 1, "cause": "timeout", "detail": ""}))
          elif seat == Azure and turn == 2:
            directive.source = dsFallback
            for attempt in 1 .. 2:
              sim.emit(writer, $(%*{
                "k": "fallback", "turn": turn, "seat": ord(seat),
                "attempt": attempt, "cause": "timeout", "detail": ""}))
          sim.activeDirective[seat] = directive
          sim.hasDirective[seat] = true
          sim.emit(writer, $directiveJson(sim, seat, directive))
    let masks = sim.compileMasks(sim.activeDirective)
    writer.writeInputFrameMasks(tickTime(sim.tickCount), masks)
    var inputs = newSeq[InputState](RobotCount)
    for i in 0 ..< RobotCount:
      inputs[i] = decodeInputMask(masks[i])
    sim.step(inputs, prev)
    prev = inputs
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
    result.hashes.add(sim.gameHash())
  sim.emit(writer, sim.resultRecordJson())
  result.sim = sim

proc writeInputFrameMasksShim() = discard

proc run() =
  let path = tempPath("replay.bitreplay")
  removeFile(path)
  let recorded = recordEpisode(path)
  doAssert fileExists(path)
  doAssert getFileSize(path) > 10_000,
    "the replay is " & $getFileSize(path) & " bytes — a truncated episode"
  report "an end-to-end episode writes a COWLDBAL replay (" &
    $getFileSize(path) & " bytes)"

  # ---- parseReplayBytes accepts it -----------------------------------------
  let bytes = readFile(path)
  doAssert bytes.startsWith(CogballReplayMagic),
    "the magic is not " & CogballReplayMagic
  let data = parseReplayBytes(bytes)
  doAssert data.gameName == GameName
  doAssert data.gameVersion == GameVersion
  doAssert data.joins.len == 2
  doAssert data.hashes.len == recorded.hashes.len
  doAssert data.inputs.len > 100, "the action log is suspiciously thin"
  for input in data.inputs:
    doAssert int(input.player) < RobotCount,
      "an input record names slot " & $input.player & ", not a ROBOT"
  report "parseReplayBytes accepts it and the masks are indexed by robot"

  # ---- the embedded config decodes strictly --------------------------------
  let config = parseJson(data.configJson)
  doAssert config["num_agents"].getInt == 2
  doAssert config["seed"].getInt == 679961
  doAssert isValidUtf8(data.configJson)
  report "the embedded config JSON decodes strictly"

  # ---- re-simulation reproduces EVERY recorded hash ------------------------
  var initialized = initReplayRuntime(
    data, mismatchQuit = true, gameEventLoggingEnabled = false)
  var sim = initSimServer(initialized.config)
  sim.gameEventLoggingEnabled = false
  var player = initReplayPlayer(data)
  player.mismatchQuit = true
  var checked = 0
  while player.hashIndex < data.hashes.len and
      sim.tickCount < player.replayMaxTick():
    player.stepReplay(sim)
    inc checked
  doAssert player.hashMismatchTick == -1,
    "the re-simulation diverged at tick " & $player.hashMismatchTick
  doAssert checked > 1000, "only " & $checked & " ticks were re-simulated"
  doAssert sim.goals(Azure) == recorded.sim.goals(Azure)
  doAssert sim.goals(Crimson) == recorded.sim.goals(Crimson)
  report "re-simulating from the config + mask log reproduces every hash"

  # ---- the record stream ---------------------------------------------------
  var kicks = 0
  var shots = 0
  var results = 0
  var directivesBySeat: array[Seat, int]
  var registers = 0
  for chat in data.chats:
    doAssert chat.message.runeLen <= MaxDirectiveRecordRunes,
      "a chat record is " & $chat.message.runeLen & " runes"
    doAssert isValidUtf8(chat.message), "a chat record is not valid UTF-8"
    let node = parseJson(chat.message)
    case node{"k"}.getStr()
    of "directive":
      inc directivesBySeat[Seat(node{"seat"}.getInt() and 1)]
      doAssert node{"robots"}.len == RobotsPerSeat
    of "register":
      inc registers
      doAssert node{"policy"}.getStr().runeLen <= MaxPolicyRunes
    of "result":
      inc results
    else: discard
  doAssert registers == 2
  doAssert results == 1, "expected exactly one result record, saw " & $results
  for seat in Seat:
    doAssert directivesBySeat[seat] >= 9,
      "only " & $directivesBySeat[seat] & " directives for " & seatAlias(seat)
  doAssert recorded.sim.stats[Azure].kicks + recorded.sim.stats[Crimson].kicks > 0
  kicks = int(recorded.sim.stats[Azure].kicks)
  shots = int(recorded.sim.stats[Azure].shots + recorded.sim.stats[Crimson].shots)
  doAssert kicks > 0, "no kick happened in a whole episode"
  doAssert shots > 0, "no shot happened in a whole episode"
  report "the record stream carries a directive per seat per turn and one result"

  # ---- the broadcast feed reads the records back ---------------------------
  var feedSim = initSimServer(initialized.config)
  feedSim.gameEventLoggingEnabled = false
  for chat in data.chats:
    feedSim.applyRecord(chat.message)
  var sawSay = false
  for line in feedSim.feed:
    if line.kind == "say" and line.text.contains("\u26BD"):
      sawSay = true
  doAssert sawSay,
    "the non-ASCII robot chatter did not reach the broadcast feed"
  report "the replay's chat records rebuild the broadcast feed, UTF-8 intact"

  # ---- tools/replay_summary.py under a STRICT UTF-8 parser -----------------
  let summaryOut = execCmdEx("python3 tools/replay_summary.py " & quoteShell(path))
  doAssert summaryOut.exitCode == 0,
    "replay_summary.py failed: " & summaryOut.output
  doAssert isValidUtf8(summaryOut.output),
    "replay_summary.py did not emit valid UTF-8"
  let summary = parseJson(summaryOut.output)
  doAssert summary["protocol"].getStr() == "cogball/v1"
  doAssert summary["gameVersion"].getStr() == GameVersion
  doAssert summary["seed"].getInt == 679961
  doAssert summary["results"]["reason"].getStr() in
    ["complete", "deadline"], summary["results"]["reason"].getStr()
  doAssert summary["directives"].len >= 18
  doAssert summary["policyLabels"][0].getStr().contains("\u00e9"),
    "the non-ASCII policy label did not survive the round trip"
  var sawEmojiSay = false
  for directive in summary["directives"]:
    for say in directive["says"]:
      if say.getStr().contains("\u26BD"):
        sawEmojiSay = true
  doAssert sawEmojiSay, "the emoji `say` did not survive to the summary"
  # `fallbacks` is the number of TURNS that fell back -- what the phase-60
  # check reads it as -- not the number of per-attempt `fallback` records.
  doAssert summary["fallbackAttempts"].getInt == 3,
    "expected three fallback ATTEMPT records, saw " &
      $summary["fallbackAttempts"].getInt
  doAssert summary["fallbacks"].getInt == 1,
    "expected one turn that actually fell back, saw " &
      $summary["fallbacks"].getInt
  var fellBack = 0
  for directive in summary["directives"]:
    if directive["source"].getStr() == "fallback":
      inc fellBack
  doAssert summary["fallbacks"].getInt == fellBack
  report "replay_summary.py output parses under a strict UTF-8 JSON parser"

  # ---- the reason is in the legal enum -------------------------------------
  let final = parseJson(recorded.sim.playerResultsJson())
  doAssert final["reason"].getStr() in ["complete", "deadline", "fault"]
  doAssert final["endRule"].getStr() in
    ["full_time", "mercy", "wall_clock", "sim_fault", "host_error"]
  report "results.reason and results.endRule are in the legal enums"

  removeFile(path)

when isMainModule:
  echo "test_replay"
  writeInputFrameMasksShim()
  run()
  echo "test_replay: all good"
