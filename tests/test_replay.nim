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

proc parkBall(sim: var SimServer, x, y: int32) =
  ## The ball dead still with the stalemate box anchored on it, and every robot
  ## parked far away along the far touchline so nothing touches it: the state
  ## the neutral drop exists to break.
  sim.ball = Ball(x: x, y: y, vx: 0, vy: 0)
  sim.anchorX = x
  sim.anchorY = y
  sim.stalemateTicks = 0
  for i in 0 ..< RobotCount:
    sim.robots[i].x = int32(6_000_000 + i * 3_000_000)
    sim.robots[i].y = 23_500_000'i32
    sim.robots[i].vx = 0
    sim.robots[i].vy = 0
    sim.robots[i].spin = 0

proc countBeats(sim: var SimServer, tracker: var BroadcastTracker,
                kind: string, ticks: int): int =
  for _ in 0 ..< ticks:
    sim.stepIdle()
    let events = newJArray()
    sim.stepEvents(tracker, events)
    for event in events:
      if event{"k"}.getStr() == kind:
        inc result

proc dropBeatsMatchRealDrops() =
  ## `drop` is a BEAT: a scrubber marker, and the trigger for the slow-mo
  ## replay. It used to be inferred from a stalemate-counter transition ("was
  ## at least 239, is now 0"), but the counter ALSO resets to 0 on the tick the
  ## ball finally leaves the box -- so a ball that escaped on its own produced
  ## a marker for a drop that never happened. The sim now records the drop and
  ## the beat is derived from that.
  let config = testConfig()

  # (a) a real drop emits exactly one beat.
  var dropped = playing(config)
  dropped.gameEventLoggingEnabled = false
  dropped.parkBall(5_000_000'i32, 5_000_000'i32)
  var trackerA = initBroadcastTracker()
  trackerA.resync(dropped)
  let real = dropped.countBeats(trackerA, "drop", config.stalemateTicks + 5)
  doAssert real == 1, "a real neutral drop emitted " & $real & " drop beats"
  doAssert dropped.lastDropTick >= 0, "the sim did not record the drop"

  # (b) a ball that LEAVES the box one tick short of the drop emits none. The
  # ball cannot cross a 1.5 m half-box in a single tick from the anchor
  # (BallMaxSpeed is 1.04 m/tick), so the escape is staged the way it happens
  # in play: the ball has already drifted to the edge of the box when the
  # counter reaches 239, and one more tick carries it out.
  var escaped = playing(config)
  escaped.gameEventLoggingEnabled = false
  escaped.parkBall(CentreX, CentreY)
  var trackerB = initBroadcastTracker()
  trackerB.resync(escaped)
  let before = escaped.countBeats(trackerB, "drop", config.stalemateTicks - 1)
  doAssert before == 0
  doAssert escaped.stalemateTicks == int32(config.stalemateTicks) - 1,
    "the counter is at " & $escaped.stalemateTicks & ", not one short"
  escaped.anchorX = escaped.ball.x - (StalemateBox - 100_000'i32)
  escaped.ball.vx = 900_000'i32
  let phantom = escaped.countBeats(trackerB, "drop", 1)
  doAssert escaped.stalemateTicks == 0, "the ball did not leave the box"
  doAssert escaped.lastDropTick < 0, "a drop actually fired"
  doAssert phantom == 0,
    "a ball that merely left the box emitted a phantom `drop` beat"
  report "the drop beat fires on a real drop and never on a counter reset"

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
  dropBeatsMatchRealDrops()
  run()
  echo "test_replay: all good"
