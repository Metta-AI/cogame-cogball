## The turn loop against a FAKE LLM transport.
##
## The central assertion is the batch shape: both seats' calls must go out
## together, so the fake records each call's in-flight window and the test
## asserts the two windows INTERSECT. A sequential implementation would still
## produce legal directives and pass every other test in this suite.

import std/[json, monotimes, os]
import lib/helpers


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
  budgetGuardFires()
  noCredentialsFallsBackInstantly()
  scriptedSeatsNeverCallOut()
  mercyAndWallClock()
  seatsAlwaysScoreToOne()
  disconnectKeepsPlaying()
  echo "test_engine: all good"
