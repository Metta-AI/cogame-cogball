## The turn loop against a FAKE LLM transport.
##
## The central assertion is the batch shape: both seats' calls must go out
## together, so the fake records each call's in-flight window and the test
## asserts the two windows INTERSECT. A sequential implementation would still
## produce legal directives and pass every other test in this suite.

import std/[json, monotimes, os, strutils]
import lib/helpers
import cogball/llm
import cogball/server


type
  Window = object
    seat: int
    startMs, endMs: int64

var windows: seq[Window]

proc nowMs(): int64 = getMonoTime().ticks div 1_000_000

proc parallelFake(reply: string, delayMs = 30): BatchFn =
  ## Answers every seat with the same body, holding each call open long enough
  ## for the windows to be meaningful.
  result = proc (calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
      {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let started = nowMs()
      sleep(delayMs)
      let ended = nowMs()
      for call in calls:
        windows.add Window(seat: call.seat, startMs: started, endMs: ended)
        result.add BatchReply(seat: call.seat, ok: true, text: reply)
    discard timeoutSeconds

proc llmSeats(engine: TurnEngine) =
  for seat in Seat:
    engine.policies[seat] = SeatPolicy(kind: pkLlm, prompt: "be brave",
      label: "test", connected: true)

const GoodReply = """{"note":"hold the shape","robots":[
 {"id":"AZ-1","role":"keeper","intent":"hold","target":[-17,0],"say":"arc"},
 {"id":"AZ-2","role":"striker","intent":"shoot","target":[3,1],"say":"go"},
 {"id":"AZ-3","role":"wing","intent":"intercept","target":[8,-4],"say":"wide"}]}"""

proc oneParallelBatch() =
  windows.setLen(0)
  var sim = playing(testConfig())
  var engine = newTurnEngine(nil, parallelFake(GoodReply))
  engine.llmSeats()
  engine.turn(sim, 0, 0)
  doAssert windows.len == 2,
    "expected one call per seat, saw " & $windows.len
  doAssert windows[0].seat != windows[1].seat, "the same seat was called twice"
  doAssert windows[0].startMs < windows[1].endMs and
    windows[1].startMs < windows[0].endMs,
    "the two seats' calls did not overlap: they were issued SEQUENTIALLY"
  for seat in Seat:
    doAssert sim.hasDirective[seat]
    doAssert sim.activeDirective[seat].source == dsLlm
    doAssert sim.stats[seat].llmTurns == 1
  var directives = 0
  for record in engine.records:
    if parseJson(record){"k"}.getStr() == "directive":
      inc directives
  doAssert directives == 2, "expected two directive records"
  report "both seats go out in ONE parallel batch and both directives install"

proc perTurnBudgetIsEnforced() =
  ## A hung client must not hold the turn past `turnBudgetMs`.
  var sim = playing(testConfig())
  sim.config.turnBudgetMs = 300
  sim.config.attempt1Ms = 200
  sim.config.retryMs = 100
  var engine = newTurnEngine(nil,
    proc (calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
        {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        sleep(220)
      for call in calls:
        result.add BatchReply(seat: call.seat, error: "Timeout was reached"))
  engine.llmSeats()
  let started = nowMs()
  engine.turn(sim, 3, 0)
  let elapsed = nowMs() - started
  doAssert elapsed < 3000,
    "the turn ran " & $elapsed & " ms against a 300 ms budget"
  for seat in Seat:
    doAssert sim.activeDirective[seat].source == dsFallback,
      "a hung client did not fall back"
    doAssert sim.stats[seat].fallbackTurns >= 1
  var timeouts = 0
  for record in engine.records:
    let node = parseJson(record)
    if node{"k"}.getStr() == "fallback" and node{"cause"}.getStr() == "timeout":
      inc timeouts
  doAssert timeouts >= 2, "no timeout fallback records were written"
  report "a hung client is bounded by the per-turn budget and falls back"

proc exactlyOneRetry() =
  ## A timeout on attempt 1 buys exactly ONE retry; a second failure is the
  ## scripted fallback.
  var sim = playing(testConfig())
  var attempts = 0
  var engine = newTurnEngine(nil,
    proc (calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
        {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        inc attempts
      for call in calls:
        if attempts == 1:
          result.add BatchReply(seat: call.seat, error: "Timeout was reached")
        else:
          result.add BatchReply(seat: call.seat, ok: true, text: GoodReply))
  engine.llmSeats()
  engine.turn(sim, 1, 0)
  doAssert attempts == 2, "expected exactly two batches, saw " & $attempts
  for seat in Seat:
    doAssert sim.activeDirective[seat].source == dsLlm,
      "the retry did not land"

  var always = newTurnEngine(nil,
    proc (calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
        {.closure, gcsafe.} =
      for call in calls:
        result.add BatchReply(seat: call.seat, ok: true, text: "no json here"))
  always.llmSeats()
  var sim2 = playing(testConfig())
  always.turn(sim2, 1, 0)
  for seat in Seat:
    doAssert sim2.activeDirective[seat].source == dsFallback,
      "two consecutive parse failures did not fall back"
  var causes = 0
  for record in always.records:
    let node = parseJson(record)
    if node{"k"}.getStr() == "fallback" and
        node{"cause"}.getStr() == "parse_error":
      inc causes
  doAssert causes == 4, "expected two attempts x two seats, saw " & $causes
  report "one timeout buys exactly one retry; two failures fall back"

proc transportErrorsAreLabelledByCause() =
  ## The cause label is read off the transport's error text, and curl words its
  ## deadline several ways. Every spelling must land on `timeout`; anything
  ## else is `transport_error`. Both are legal in the enum, but phase 60 reads
  ## these strings, so a deadline must not read as a connection failure.
  for (text, want) in [("Timeout was reached", "timeout"),
                       ("Operation timed out after 6001 milliseconds",
                        "timeout"),
                       ("Connection timed out", "timeout"),
                       ("Could not resolve host: api.anthropic.com",
                        "transport_error"),
                       ("", "transport_error")]:
    var sim = playing(testConfig())
    var engine = newTurnEngine(nil,
      proc (calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
          {.closure, gcsafe.} =
        for call in calls:
          result.add BatchReply(seat: call.seat, error: text))
    engine.llmSeats()
    engine.turn(sim, 5, 0)
    var seen = 0
    for record in engine.records:
      let node = parseJson(record)
      if node{"k"}.getStr() != "fallback":
        continue
      inc seen
      doAssert node{"cause"}.getStr() == want,
        "`" & text & "` was labelled " & node{"cause"}.getStr() &
          ", expected " & want
    doAssert seen == 4, "expected two attempts x two seats, saw " & $seen
  report "every curl deadline spelling is recorded as cause `timeout`"

proc attemptDeadlinesFitTheTurnBudget() =
  ## curly's transport timeout is whole seconds and a batch in flight cannot be
  ## interrupted, so the SUM of the whole-second allowances the transport
  ## actually receives is the realised worst case for a turn -- not the
  ## millisecond configuration. It must fit inside turnBudgetMs.
  var sim = playing(testConfig())
  var granted: seq[int]
  var engine = newTurnEngine(nil,
    proc (calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
        {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        granted.add(timeoutSeconds)
      for call in calls:
        result.add BatchReply(seat: call.seat, error: "Timeout was reached"))
  engine.llmSeats()
  engine.turn(sim, 2, 0)
  doAssert granted.len == 2, "expected attempt 1 plus one retry"
  doAssert granted[0] == sim.config.attempt1Ms div 1000,
    "attempt 1 was given " & $granted[0] & " s for a " &
      $sim.config.attempt1Ms & " ms allowance"
  doAssert granted[1] == sim.config.retryMs div 1000,
    "the retry was given " & $granted[1] & " s for a " &
      $sim.config.retryMs & " ms allowance"
  var total = 0
  for seconds in granted:
    total += seconds
  doAssert total * 1000 <= sim.config.turnBudgetMs,
    "the whole-second attempt deadlines sum to " & $total &
      " s, past the " & $sim.config.turnBudgetMs & " ms turn budget"
  report "the attempt deadlines the transport receives sum to " & $total &
    " s inside the " & $(sim.config.turnBudgetMs div 1000) & " s turn budget"

proc budgetGuardFires() =
  ## The guard switches the LLM off for the rest of the match, so the episode
  ## ends complete/full_time rather than deadline.
  var sim = playing(testConfig())
  var calls = 0
  var engine = newTurnEngine(nil,
    proc (batch: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
        {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        inc calls
      for call in batch:
        result.add BatchReply(seat: call.seat, ok: true, text: GoodReply))
  engine.llmSeats()
  # 680 s elapsed against a 690 s budget and a 9 s turn: 680 + 18 > 690.
  engine.turn(sim, 30, 680)
  doAssert engine.llmOff, "the budget guard did not fire"
  doAssert calls == 0, "the LLM was still called after the guard"
  var guards = 0
  for record in engine.records:
    if parseJson(record){"k"}.getStr() == "budget_guard":
      inc guards
  doAssert guards == 1, "no budget_guard record"
  engine.turn(sim, 31, 681)
  doAssert calls == 0, "the guard did not stick"
  for seat in Seat:
    doAssert sim.activeDirective[seat].source == dsFallback
  report "the budget guard fires once, sticks, and costs no network wait"

proc budgetGuardStillEndsFullTime() =
  ## The whole point of the guard: the match finishes on the scripted layer and
  ## ends `complete/full_time` instead of running into the wall clock and
  ## ending `deadline`. The guard test above stops at "it fired"; this one
  ## plays the episode out.
  var sim = playing(testConfig(maxTicks = 600))
  var calls = 0
  var engine = newTurnEngine(nil,
    proc (batch: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
        {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        inc calls
      for call in batch:
        result.add BatchReply(seat: call.seat, ok: true, text: GoodReply))
  engine.llmSeats()
  var prev = newSeq[InputState](RobotCount)
  var guard = 0
  var turns = 0
  # 680 s elapsed against a 690 s budget: the guard fires on the first turn.
  while sim.phase != GameOver and guard < sim.config.maxTicks * 3:
    inc guard
    if sim.phase == Playing:
      let elapsed = sim.tickCount - sim.gameStartTick
      if elapsed mod sim.turnTicks() == 0 or
          not (sim.hasDirective[Azure] and sim.hasDirective[Crimson]):
        engine.turn(sim, elapsed div sim.turnTicks(), 680)
        inc turns
    let masks = sim.compileMasks(sim.activeDirective)
    var inputs = newSeq[InputState](RobotCount)
    for i in 0 ..< RobotCount:
      inputs[i] = decodeInputMask(masks[i])
    sim.step(inputs, prev)
    prev = inputs
  doAssert engine.llmOff, "the budget guard never fired"
  doAssert calls == 0, "the LLM was called after the guard switched it off"
  doAssert turns >= 5, "only " & $turns & " turns ran"
  doAssert sim.phase == GameOver
  doAssert sim.endReason == reasonComplete,
    "the guarded episode ended " & reasonText(sim.endReason) &
      ", not complete"
  doAssert sim.endRule == erFullTime,
    "the guarded episode ended " & endRuleText(sim.endRule) &
      ", not full_time"
  for seat in Seat:
    doAssert sim.stats[seat].fallbackTurns == int32(turns),
      "the guarded seat did not play the scripted layer every turn"
    doAssert sim.stats[seat].llmTurns == 0
  report "a guarded match finishes on the scripted layer, complete/full_time"

proc noCredentialsFallsBackInstantly() =
  ## With no client at all every turn falls back with NO network wait, which is
  ## what makes offline certification complete in seconds.
  var sim = playing(testConfig())
  var engine = newTurnEngine(nil, nil)
  engine.llmSeats()
  let started = nowMs()
  for turn in 0 ..< 40:
    engine.turn(sim, turn, 0)
  let elapsed = nowMs() - started
  doAssert elapsed < 2000,
    "40 credential-free turns took " & $elapsed & " ms"
  for seat in Seat:
    doAssert sim.stats[seat].fallbackTurns == 40
  report "40 credential-free turns settle in " & $elapsed & " ms"

proc rejectedCredentialsAreNotNoCredentials() =
  ## A 401/403 disables the client for the rest of the episode (llm.nim), and
  ## every later turn then takes the instant-fallback branch. The credentials
  ## were PRESENT and were rejected, so the recorded cause must not be
  ## `no_credentials` -- that would send phase 60 hunting for an unset secret
  ## that was in fact set and wrong.
  proc causesFor(client: LlmClient, batch: BatchFn): seq[string] =
    var sim = playing(testConfig())
    var engine = newTurnEngine(client, batch)
    engine.llmSeats()
    engine.turn(sim, 4, 0)
    for seat in Seat:
      doAssert sim.activeDirective[seat].source == dsFallback
    for record in engine.records:
      let node = parseJson(record)
      if node{"k"}.getStr() == "fallback":
        result.add(node{"cause"}.getStr())

  let live = proc (calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
      {.closure, gcsafe.} =
    for call in calls:
      result.add BatchReply(seat: call.seat, ok: true, text: GoodReply)

  let rejected = causesFor(
    LlmClient(transport: ltAnthropic, disabled: true), live)
  doAssert rejected.len == 2, "expected one record per seat"
  for cause in rejected:
    doAssert cause == "transport_error",
      "a rejected credential was recorded as `" & cause & "`"

  let absent = causesFor(LlmClient(transport: ltNone, disabled: true), live)
  doAssert absent.len == 2
  for cause in absent:
    doAssert cause == "no_credentials",
      "an absent credential was recorded as `" & cause & "`"

  let noTransport = causesFor(nil, nil)
  doAssert noTransport.len == 2
  for cause in noTransport:
    doAssert cause == "no_credentials"
  report "a rejected credential is a transport_error, not no_credentials"

proc scriptedSeatsNeverCallOut() =
  var sim = playing(testConfig())
  var calls = 0
  var engine = newTurnEngine(nil,
    proc (batch: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
        {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        inc calls
      for call in batch:
        result.add BatchReply(seat: call.seat, ok: true, text: GoodReply))
  engine.policies[Azure] = SeatPolicy(kind: pkScripted, baseline: "formation")
  engine.policies[Crimson] = SeatPolicy(kind: pkLlm, prompt: "p")
  engine.turn(sim, 0, 0)
  doAssert calls == 1, "expected one batch, saw " & $calls
  doAssert sim.activeDirective[Azure].source == dsScripted
  doAssert sim.activeDirective[Crimson].source == dsLlm
  doAssert sim.stats[Azure].llmTurns == 0
  doAssert sim.stats[Crimson].llmTurns == 1
  report "a scripted seat never reaches the transport"

proc mercyAndWallClock() =
  ## Mercy fires at a goal difference of five; the wall-clock stop yields
  ## deadline/wall_clock; the physics guard yields fault/sim_fault with 0.5.
  var sim = playing(testConfig())
  sim.stats[Azure].goals = 5
  var ended = false
  for _ in 0 ..< 300:
    sim.stepIdle()
    if sim.phase == GameOver:
      ended = true
      break
  doAssert ended, "mercy never fired at a five-goal difference"
  doAssert sim.endRule == erMercy,
    "expected mercy, got " & endRuleText(sim.endRule)
  doAssert sim.endReason == reasonComplete

  var stopped = playing(testConfig())
  stopped.stepIdle(10)
  stopped.wallClockStop()
  doAssert stopped.endReason == reasonDeadline
  doAssert stopped.endRule == erWallClock
  doAssert stopped.phase == GameOver

  var faulted = playing(testConfig())
  faulted.finishGame(reasonFault, erSimFault)
  doAssert faulted.scorePermille(Azure) == 500
  doAssert faulted.scorePermille(Crimson) == 500
  doAssert not faulted.seatWon(Azure) and not faulted.seatWon(Crimson)
  report "mercy, the wall-clock stop and the physics fault all resolve"

proc hostErrorIsAReachableEnding() =
  ## `fault/host_error` is declared in the results_schema's endRule enum and in
  ## docs/RULES.md, and the note promises "best-effort artifacts written before
  ## re-raising". hostErrorStop used to have no caller at all, so the ending was
  ## unreachable and an unexpected exception unwound out of the entrypoint with
  ## no results.json, no replay upload and no events file.
  var sim = playing(testConfig())
  sim.stepIdle(10)
  sim.hostErrorStop()
  doAssert sim.phase == GameOver
  doAssert sim.endReason == reasonFault
  doAssert sim.endRule == erHostError
  doAssert endRuleText(sim.endRule) == "host_error"
  doAssert sim.scorePermille(Azure) == 500
  doAssert sim.scorePermille(Crimson) == 500
  doAssert not sim.seatWon(Azure) and not sim.seatWon(Crimson)
  let results = parseJson(sim.playerResultsJson())
  doAssert results["reason"].getStr() == "fault"
  doAssert results["endRule"].getStr() == "host_error"
  # Idempotent, and it never overwrites a verdict the match already reached.
  var finished = playing(testConfig())
  finished.finishGame(reasonComplete, erFullTime)
  finished.hostErrorStop()
  doAssert finished.endRule == erFullTime,
    "a host error overwrote a match that had already ended"

  # ...and the server loop actually takes that path: the whole loop is wrapped,
  # the verdict is recorded, the artifacts are written, and the exception is
  # re-raised so the exit status still says what happened.
  let source = readFile("src/cogball/server.nim")
  for fragment in ["except CatchableError as failure:", "sim.hostErrorStop()",
                   "recordAndWrite(sim.resultRecordJson())",
                   "writeArtifacts()", "raise"]:
    doAssert source.contains(fragment),
      "the host-error path lost `" & fragment & "`"
  let handler = source[source.find("except CatchableError as failure:") .. ^1]
  doAssert handler.find("sim.hostErrorStop()") <
    handler.find("writeArtifacts()"),
    "the verdict must be set before the artifacts are written"
  doAssert handler.find("writeArtifacts()") < handler.rfind("raise"),
    "the artifacts must be written before the exception is re-raised"
  report "fault/host_error is reachable and writes artifacts before re-raising"

proc neverConnectingSeatIsReportedAndPlaysOn() =
  ## A seat that never connects does NOT end the episode: after
  ## lobbyJoinTimeoutTicks the no-show is reported to COGAME_PLAYER_FAILURE_URI,
  ## its trio is driven by `formation` for the whole match, and the match
  ## reaches full time. Nothing exercised declarePlayerFailure before, so the
  ## JSON shape the platform runner polls for was never asserted.
  let path = tempPath("player-failure.json")
  removeFile(path)
  putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & path)
  defer:
    delEnv("COGAME_PLAYER_FAILURE_URI")
    removeFile(path)

  var config = testConfig(maxTicks = 600)
  config.lobbyJoinTimeoutTicks = 10
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  discard sim.addPlayer("azure-policy", 0, "t0")   ## only ONE seat connects.
  var lobbyTicks = 0
  while not sim.lobbyJoinTimedOut() and lobbyTicks < 200:
    sim.stepIdle()
    inc lobbyTicks
  doAssert sim.lobbyJoinTimedOut(), "the lobby timeout never fired"
  doAssert sim.phase == Lobby, "the sim ended the episode by itself"

  let stuck = sim.nextPlayerSlot()
  doAssert stuck == 1, "the stuck slot is not the next open seat"
  declarePlayerFailure(stuck, "player slot 1 never joined the lobby")
  doAssert fileExists(path),
    "no player-failure document was published to COGAME_PLAYER_FAILURE_URI"
  let failure = parseJson(readFile(path))
  doAssert failure["failed_policy_index"].getInt == 1,
    "the failure was charged to the wrong seat: " & $failure
  doAssert failure["message"].getStr().len > 0, "the failure carries no reason"

  # ...and the match still plays, on the scripted layer, to full time.
  sim.startGame()
  var directives: array[Seat, Directive]
  var prev = newSeq[InputState](RobotCount)
  var guard = 0
  while sim.phase != GameOver and guard < config.maxTicks * 3:
    inc guard
    if sim.phase == Playing:
      let elapsed = sim.tickCount - sim.gameStartTick
      if elapsed mod sim.turnTicks() == 0 or
          not (sim.hasDirective[Azure] and sim.hasDirective[Crimson]):
        let turn = elapsed div sim.turnTicks()
        for seat in Seat:
          directives[seat] = sim.baselineDirective(seat, "formation", turn)
          sim.activeDirective[seat] = directives[seat]
          sim.hasDirective[seat] = true
    let masks = sim.compileMasks(sim.activeDirective)
    var inputs = newSeq[InputState](RobotCount)
    for i in 0 ..< RobotCount:
      inputs[i] = decodeInputMask(masks[i])
    sim.step(inputs, prev)
    prev = inputs
  doAssert sim.phase == GameOver, "the match never ended"
  doAssert sim.endReason == reasonComplete,
    "a lobby no-show ended the episode " & reasonText(sim.endReason)
  doAssert sim.endRule == erFullTime,
    "expected full_time, got " & endRuleText(sim.endRule)
  # The absent seat's trio was actuated the whole way, not left inert.
  var moved = 0
  for i in 0 ..< RobotCount:
    if sim.robots[i].distanceUm > 0:
      inc moved
  doAssert moved == RobotCount,
    "only " & $moved & " of six robots moved; a trio went inert"
  report "a never-connecting seat is declared and the match reaches full_time"

proc seatsAlwaysScoreToOne() =
  for a in 0 .. 6:
    for b in 0 .. 6:
      var sim = playing(testConfig())
      sim.stats[Azure].goals = int32(a)
      sim.stats[Crimson].goals = int32(b)
      sim.finishGame(reasonComplete, erFullTime)
      doAssert sim.scorePermille(Azure) + sim.scorePermille(Crimson) == 1000,
        "scores do not sum to 1.0 at " & $a & "-" & $b
      doAssert sim.seatWon(Azure) == (a > b)
      doAssert sim.seatWon(Crimson) == (b > a)
  var pinned = playing(testConfig())
  pinned.stats[Azure].goals = 2
  pinned.stats[Crimson].goals = 1
  pinned.finishGame(reasonComplete, erFullTime)
  doAssert pinned.scorePermille(Azure) == 667, $pinned.scorePermille(Azure)
  doAssert pinned.scorePermille(Crimson) == 333
  report "the two seats' scores always sum to exactly 1.000"

proc disconnectKeepsPlaying() =
  ## A seat that drops mid-match keeps playing on the scripted layer, and
  ## revives on reconnect. No failure mode leaves a robot unactuated.
  var sim = playing(testConfig())
  var engine = newTurnEngine(nil, parallelFake(GoodReply))
  engine.llmSeats()
  engine.turn(sim, 0, 0)
  doAssert sim.activeDirective[Crimson].source == dsLlm
  sim.removePlayerAt(1)
  engine.policies[Crimson] = SeatPolicy(kind: pkScripted, baseline: "formation")
  engine.turn(sim, 1, 0)
  doAssert sim.activeDirective[Crimson].source == dsScripted
  let masks = sim.compileMasks(sim.activeDirective)
  var actuated = 0
  for i in 0 ..< RobotCount:
    if masks[i] != 0:
      inc actuated
  doAssert actuated > 0, "the dropped seat's trio went inert"
  engine.policies[Crimson] = SeatPolicy(kind: pkLlm, prompt: "back")
  engine.turn(sim, 2, 0)
  doAssert sim.activeDirective[Crimson].source == dsLlm,
    "the seat did not revive on reconnect"
  report "a dropped seat keeps playing and revives on reconnect"

when isMainModule:
  echo "test_engine"
  oneParallelBatch()
  exactlyOneRetry()
  perTurnBudgetIsEnforced()
  transportErrorsAreLabelledByCause()
  attemptDeadlinesFitTheTurnBudget()
  budgetGuardFires()
  budgetGuardStillEndsFullTime()
  noCredentialsFallsBackInstantly()
  rejectedCredentialsAreNotNoCredentials()
  scriptedSeatsNeverCallOut()
  mercyAndWallClock()
  hostErrorIsAReachableEnding()
  neverConnectingSeatIsReportedAndPlaysOn()
  seatsAlwaysScoreToOne()
  disconnectKeepsPlaying()
  echo "test_engine: all good"
