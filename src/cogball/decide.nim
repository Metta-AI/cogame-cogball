## The turn engine: one decision every 120 ticks, both seats issued as ONE
## parallel batch, two bounded attempts, then the scripted fallback.
##
## Timing (docs/RULES.md §Budget):
##   attempt 1 batch deadline   6.0 s   (config attempt1Ms)
##   retry batch deadline       2.5 s   (config retryMs)
##   outer monotonic turn cap   9.0 s   (config turnBudgetMs)
## 40 turns x 9.0 s = 360 s against a 720 s budget, with a 690 s engine stop.
##
## Seats are NEVER queried sequentially. The transport is injected as a
## `BatchFn` so tests/test_engine.nim can hand in a fake that records each
## call's in-flight window and assert the two windows intersect.

import
  std/[json, monotimes, strutils, times],
  curly,
  sim, directives, baselines, llm

const SystemPrompt* = """You are the coach of a three-robot soccer team in a continuous 2D physics world.
Every 5 seconds of match time you issue ONE directive for all three of your robots.
A deterministic controller executes it for the next 5 seconds: it steers each robot
toward its target, turns it to face where it is going, and kicks when the ball is in
range and the intent allows it. You do not control motors directly.
The pitch is 40 by 25 metres and FULLY WALLED - there is no out of play, no corners,
no throw-ins and no offside. The controller will not let a robot bury the ball on the
boards: near a wall it aims its kick back toward the middle.
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"note":"<=160 chars","robots":[
  {"id":"<one of your three robot ids>",
   "role":"keeper|back|wing|striker",
   "intent":"chase|intercept|hold|shoot|pass|clear|press",
   "target":[x,y],            // metres, x in [-20,20], y in [-12.5,12.5]
   "pass_to":"<teammate id or null>",
   "kick":"auto|never",
   "say":"<=48 chars"} , ... exactly three, one per robot ]}
Intents: chase = drive at the ball; intercept = drive to where the ball will be;
hold = hold the target point and face the ball; shoot = line up behind the ball and
strike it at their goal; pass = same but aimed at pass_to; clear = hammer it away
from your own goal; press = shadow the nearest opponent. target is used directly by
hold and as a bias by the others. kick:"never" makes the robot shepherd the ball
instead of striking it."""

type
  BatchCall* = object
    seat*: int
    system*, user*: string

  BatchReply* = object
    seat*: int
    ok*: bool
    text*: string
    error*: string

  BatchFn* = proc (
    calls: seq[BatchCall],
    timeoutSeconds: int
  ): seq[BatchReply] {.closure, gcsafe.}

  SeatPolicy* = object
    kind*: PolicyKind
    prompt*: string            ## never recorded, never echoed.
    baseline*: string
    label*: string
    connected*: bool

  TurnEngine* = ref object
    client*: LlmClient
    batch*: BatchFn
    policies*: array[Seat, SeatPolicy]
    previous*: array[Seat, Directive]
    hasPrevious*: array[Seat, bool]
    lastStats*: array[Seat, SeatStats]
    lastGoals*: seq[JsonNode]
    llmOff*: bool
    guardTurn*: int
    records*: seq[string]      ## the replay chat records this turn produced.

# --------------------------------------------------------------------------
# The per-seat view
# --------------------------------------------------------------------------

proc robotViewJson(sim: SimServer, index: int, own: bool): JsonNode =
  let
    r = sim.robots[index]
    h = r.headingVec()
    dist = distI(sim.ball.x - r.x, sim.ball.y - r.y)
  result = %*{
    "id": robotId(index),
    "pos": [round2(viewX(r.x)), round2(viewY(r.y))],
    "vel": [round2(float(r.vx) * 24.0 / 1_000_000.0),
            round2(float(r.vy) * 24.0 / 1_000_000.0)],
    "facing": [round2(float(h.x) / 4096.0), round2(float(h.y) / 4096.0)],
    "speed": round2(float(speedOf(r.vx, r.vy)) * 24.0 / 1_000_000.0),
    "dist_to_ball": round2(float(dist) / 1_000_000.0)
  }
  if own:
    result["kick_ready"] = %(r.kickCooldown == 0)

proc possessionText(sim: SimServer): string =
  if sim.lastTouch.robot < 0:
    return "loose"
  # The ball counts as held only while its last toucher is still on it.
  let i = int(sim.lastTouch.robot)
  if distI(sim.ball.x - sim.robots[i].x, sim.ball.y - sim.robots[i].y) <=
      RobotRadius + BallRadius + 400_000'i32:
    robotId(i)
  else:
    "loose"

proc seatViewJson*(
  engine: TurnEngine,
  sim: SimServer,
  seat: Seat,
  turn: int
): JsonNode =
  ## Everything the seat's coach sees, in view coordinates (metres, centred),
  ## rounded to two decimals. Never contains a real player name, the seed, the
  ## opponent's directives, or any future tick.
  let
    played = float(sim.gameTicksElapsed()) / float(TargetFps)
    total = float(sim.config.maxTicks) / float(TargetFps)
    me = sim.stats[seat]
    them = sim.stats[other(seat)]
    prevMe = engine.lastStats[seat]
    prevThem = engine.lastStats[other(seat)]
    possMe = me.possessionTicks - prevMe.possessionTicks
    possThem = them.possessionTicks - prevThem.possessionTicks
    possTotal = max(1, int(possMe + possThem))
  var yours = newJArray()
  var theirs = newJArray()
  for slot in 0 ..< RobotsPerSeat:
    var own = robotViewJson(sim, firstRobotOf(seat) + slot, true)
    if engine.hasPrevious[seat]:
      own["last_role"] = %roleText(engine.previous[seat].robots[slot].role)
    yours.add(own)
    theirs.add(robotViewJson(sim, firstRobotOf(other(seat)) + slot, false))
  let penalty =
    if attackDir(seat) > 0: "x <= -14, |y| <= 7" else: "x >= 14, |y| <= 7"
  var goalsJson = newJArray()
  for entry in engine.lastGoals:
    var copy = copy(entry)
    copy["for"] = %(if entry{"seat"}.getInt() == ord(seat): "you" else: "them")
    copy.delete("seat")
    goalsJson.add(copy)
  result = %*{
    "turn": turn,
    "of": sim.turnCount(),
    "clock": {"played_s": round2(played), "left_s": round2(total - played)},
    "score": {"you": sim.goals(seat), "them": sim.goals(other(seat))},
    "you": {
      "alias": seatAlias(seat),
      "attacking_x": (if attackDir(seat) > 0: "+20" else: "-20"),
      "defending_x": (if attackDir(seat) > 0: "-20" else: "+20")
    },
    "pitch": {
      "x_min": -ViewHalfW, "x_max": ViewHalfW,
      "y_min": -ViewHalfH, "y_max": ViewHalfH,
      "goal_half_width": GoalHalfWidth,
      "your_penalty_area": penalty,
      "walled": true
    },
    "ball": {
      "pos": [round2(viewX(sim.ball.x)), round2(viewY(sim.ball.y))],
      "vel": [round2(float(sim.ball.vx) * 24.0 / 1_000_000.0),
              round2(float(sim.ball.vy) * 24.0 / 1_000_000.0)],
      "speed": round2(float(speedOf(sim.ball.vx, sim.ball.vy)) * 24.0 /
        1_000_000.0),
      "possession": possessionText(sim),
      "in_your_half": sim.ballInOwnHalf(seat),
      "on_boards": onBoards(sim.ball.x, sim.ball.y)
    },
    "your_robots": yours,
    "their_robots": theirs,
    "last_turn": {
      "your_kicks": int(me.kicks - prevMe.kicks),
      "their_kicks": int(them.kicks - prevThem.kicks),
      "your_shots": int(me.shots - prevMe.shots),
      "their_shots": int(them.shots - prevThem.shots),
      "possession_pct_you": int(possMe) * 100 div possTotal,
      "goals": goalsJson
    },
    "your_last_directive": (
      if engine.hasPrevious[seat]:
        directiveJson(sim, seat, engine.previous[seat])
      else:
        newJNull())
  }

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc userMessage*(
  engine: TurnEngine,
  sim: SimServer,
  seat: Seat,
  turn: int
): string =
  operatorBlock(engine.policies[seat].prompt) &
    $engine.seatViewJson(sim, seat, turn)

# --------------------------------------------------------------------------
# The transport
# --------------------------------------------------------------------------

proc curlyBatch*(client: LlmClient): BatchFn =
  ## The production transport: ONE `curly.makeRequests` call per attempt, so
  ## both seats are in flight together. curly's timeout is whole seconds, so a
  ## sub-second budget rounds UP here and the outer monotonic turn deadline
  ## keeps the real cap.
  result = proc (calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
      {.closure, gcsafe.} =
    result = @[]
    if calls.len == 0:
      return
    var batch: RequestBatch
    for call in calls:
      let request = client.requestFor(call.system, call.user)
      batch.post(request.url, request.headers, request.body, $call.seat)
    let responses = client.curl.makeRequests(batch, max(1, timeoutSeconds))
    for i, call in calls:
      var reply = BatchReply(seat: call.seat)
      if i >= responses.len:
        reply.error = "no response"
        result.add(reply)
        continue
      let (response, error) = responses[i]
      if error.len > 0:
        reply.error = error
      else:
        try:
          reply.text = client.completionText(response.code, response.body)
          reply.ok = true
        except CatchableError as failure:
          reply.error = failure.msg
      result.add(reply)

# --------------------------------------------------------------------------
# The turn
# --------------------------------------------------------------------------

proc newTurnEngine*(client: LlmClient, batch: BatchFn): TurnEngine =
  result = TurnEngine(client: client, batch: batch, guardTurn: -1)
  for seat in Seat:
    result.previous[seat] = emptyDirective(seat)

proc addRecord(engine: TurnEngine, node: JsonNode) =
  engine.records.add(capRecord($node))

proc noteGoal*(engine: TurnEngine, tick: int, robot: int, seat: Seat) =
  ## Called by the server when a goal lands, so the next turn's view can
  ## report it. Bounded to the last handful.
  engine.lastGoals.add(%*{
    "tick": tick,
    "by": (if robot >= 0: robotId(robot) else: "own goal"),
    "seat": ord(seat)
  })
  while engine.lastGoals.len > 4:
    engine.lastGoals.delete(0)

proc fallbackFor(
  engine: TurnEngine,
  sim: SimServer,
  seat: Seat,
  turn: int
): Directive =
  ## The `formation` directive is the fallback for every failure mode.
  result = sim.formationDirective(seat, turn)
  result.source = dsFallback

proc turn*(
  engine: TurnEngine,
  sim: var SimServer,
  turnIndex: int,
  elapsedSeconds: int
) =
  ## Runs one decision turn: at most one parallel batch plus at most one
  ## parallel retry, all inside a monotonic `turnBudgetMs` bound, then installs
  ## both seats' directives and writes the records.
  engine.records.setLen(0)
  let
    deadline = getMonoTime() + initDuration(
      milliseconds = max(1, sim.config.turnBudgetMs))
    budget = sim.config.wallClockBudgetSeconds
    perTurn = (sim.config.turnBudgetMs + 999) div 1000

  # Budget guard: switch the LLM off for the rest of the match rather than let
  # the episode end `deadline`. Microseconds per turn from here on.
  if not engine.llmOff and elapsedSeconds + 2 * perTurn > budget:
    engine.llmOff = true
    engine.guardTurn = turnIndex
    engine.addRecord(%*{
      "k": "budget_guard",
      "turn": turnIndex,
      "remaining_s": budget - elapsedSeconds
    })
    echo "cogball: budget guard at turn ", turnIndex,
      "; falling back to the scripted layer for the rest of the match"

  var
    resolved: array[Seat, Directive]
    settled: array[Seat, bool]
    calls: seq[BatchCall]
  for seat in Seat:
    let policy = engine.policies[seat]
    if policy.kind == pkScripted:
      resolved[seat] = sim.baselineDirective(seat, policy.baseline, turnIndex)
      settled[seat] = true
    elif engine.llmOff or engine.batch.isNil or
        (not engine.client.isNil and engine.client.disabled):
      # A nil CLIENT with a live batch is the test seam (tests/test_engine.nim
      # injects a fake transport); a nil BATCH is the real no-credentials path.
      resolved[seat] = engine.fallbackFor(sim, seat, turnIndex)
      settled[seat] = true
      let cause =
        if engine.llmOff: "budget_guard"
        else: "no_credentials"
      engine.addRecord(%*{
        "k": "fallback", "turn": turnIndex, "seat": ord(seat),
        "attempt": 1, "cause": cause, "detail": ""
      })
    else:
      calls.add BatchCall(
        seat: ord(seat),
        system: SystemPrompt,
        user: engine.userMessage(sim, seat, turnIndex))

  var attempt = 1
  while calls.len > 0 and attempt <= 2:
    let
      remainingMs = (deadline - getMonoTime()).inMilliseconds
      wantMs = if attempt == 1: sim.config.attempt1Ms else: sim.config.retryMs
      allowedMs = min(wantMs, int(max(0'i64, remainingMs)))
    if allowedMs <= 0:
      break
    let started = getMonoTime()
    var replies: seq[BatchReply]
    try:
      replies = engine.batch(calls, (allowedMs + 999) div 1000)
    except CatchableError as failure:
      replies = @[]
      for call in calls:
        replies.add BatchReply(seat: call.seat, error: failure.msg)
    let latency = int32((getMonoTime() - started).inMilliseconds)
    var retry: seq[BatchCall]
    for reply in replies:
      let seat = Seat(reply.seat and 1)
      var cause = ""
      var detail = reply.error
      if not reply.ok:
        # curl words its deadline several ways ("Timeout was reached",
        # "Operation timed out after ...", "Connection timed out"), so match on
        # the lowercased text and on both spellings. Either label is legal in
        # the cause enum; the point is that a deadline reads as a deadline in
        # the record phase 60 counts.
        let text = reply.error.toLowerAscii()
        cause =
          if text.contains("timeout") or text.contains("timed out"): "timeout"
          else: "transport_error"
      else:
        try:
          let payload = extractJsonObject(reply.text)
          let parsed = parseDirective(sim, seat, payload,
            engine.previous[seat], engine.hasPrevious[seat],
            sim.formationDirective(seat, turnIndex), turnIndex)
          if parsed.usable:
            resolved[seat] = parsed.directive
            resolved[seat].latencyMs = latency
            settled[seat] = true
          else:
            cause = "parse_error"
            detail = "no usable robot entry"
        except CatchableError as failure:
          cause = "parse_error"
          detail = failure.msg
      if cause.len > 0:
        engine.addRecord(%*{
          "k": "fallback", "turn": turnIndex, "seat": ord(seat),
          "attempt": attempt, "cause": cause,
          "detail": clipRunes(detail, MaxDetailRunes)
        })
        for call in calls:
          if call.seat == reply.seat:
            retry.add call
    calls = retry
    inc attempt

  for call in calls:
    # Two consecutive failures: the seat plays `formation` this turn.
    let seat = Seat(call.seat and 1)
    resolved[seat] = engine.fallbackFor(sim, seat, turnIndex)
    settled[seat] = true

  for seat in Seat:
    if not settled[seat]:
      resolved[seat] = engine.fallbackFor(sim, seat, turnIndex)
    resolved[seat].turn = int32(turnIndex)
    sim.activeDirective[seat] = resolved[seat]
    sim.hasDirective[seat] = true
    engine.previous[seat] = resolved[seat]
    engine.hasPrevious[seat] = true
    case resolved[seat].source
    of dsLlm: inc sim.stats[seat].llmTurns
    of dsFallback: inc sim.stats[seat].fallbackTurns
    of dsScripted: discard
    # The record is the ONE source: the server writes it to the replay AND
    # folds it back through `applyRecord`, so the feed reads identically live
    # and in playback.
    engine.addRecord(directiveJson(sim, seat, resolved[seat]))

  for seat in Seat:
    engine.lastStats[seat] = sim.stats[seat]
  engine.lastGoals.setLen(0)
