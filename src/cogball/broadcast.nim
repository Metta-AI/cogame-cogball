## Replay broadcast state channel.
##
## Derives the designed broadcast client's JSON chrome state from the live sim,
## and folds the replay's chat records back into the non-hashed presentation
## fields so the feed reads identically live and in playback.
##
## Beat-event derivation works ONE SIM STEP AT A TIME (`stepEvents`) and is
## accumulated by the caller across a playback frame, so attribution stays
## exact even at 16x — never collapsing a whole span into one ambiguous marker.
## Kept from ctf; the vocabulary is cogball's.

import
  std/[json, strutils],
  sim, roster, global

type
  BroadcastTracker* = object
    ## Per-server snapshot used to diff one sim step against the previous one.
    initialized: bool
    prevTick: int
    prevPhase: GamePhase
    goals: array[Seat, int32]
    kicks: array[Seat, int32]
    shots: array[Seat, int32]
    onTarget: array[Seat, int32]
    saves: array[Seat, int32]
    passes: array[Seat, int32]
    interceptions: array[Seat, int32]
    lastTouchRobot: int32
    lastTouchTick: int32
    lastGoalTick: int32
    lastDropTick: int32
    posts: int
    stalemate: int32
    turn: int

proc initBroadcastTracker*(): BroadcastTracker =
  result.prevPhase = Lobby
  result.lastTouchRobot = -1
  result.lastGoalTick = -1
  result.lastDropTick = -1
  result.turn = -1

proc snapshot(tracker: var BroadcastTracker, sim: SimServer) =
  for seat in Seat:
    tracker.goals[seat] = sim.stats[seat].goals
    tracker.kicks[seat] = sim.stats[seat].kicks
    tracker.shots[seat] = sim.stats[seat].shots
    tracker.onTarget[seat] = sim.stats[seat].shotsOnTarget
    tracker.saves[seat] = sim.stats[seat].saves
    tracker.passes[seat] = sim.stats[seat].passesCompleted
    tracker.interceptions[seat] = sim.stats[seat].interceptions
  tracker.lastTouchRobot = sim.lastTouch.robot
  tracker.lastTouchTick = sim.lastTouch.tick
  tracker.lastGoalTick = sim.lastGoalTick
  tracker.lastDropTick = sim.lastDropTick
  tracker.stalemate = sim.stalemateTicks
  tracker.prevTick = sim.tickCount
  tracker.prevPhase = sim.phase
  tracker.turn = sim.currentTurn()
  tracker.initialized = true

proc resync*(tracker: var BroadcastTracker, sim: SimServer) =
  ## Snapshots without emitting events, after a seek/loop/skip. The next
  ## `stepEvents` then diffs against this frame, so no phantom beats fire.
  tracker.snapshot(sim)

proc stepEvents*(
  sim: SimServer,
  tracker: var BroadcastTracker,
  events: JsonNode
) =
  ## Appends the beat events produced by the transition from the tracker's last
  ## snapshot to the current sim tick, then advances the tracker. `goal` and
  ## `drop` are BEATS: scrubber markers, and the trigger for the slow-mo goal
  ## replay. `touch` is throttled to at most one per robot per 6 ticks.
  if not tracker.initialized:
    tracker.snapshot(sim)
    return
  let tick = sim.tickCount

  if sim.phase != tracker.prevPhase:
    events.add(%*{"t": tick, "k": "phase",
      "phase": ($sim.phase).toLowerAscii})
    if sim.phase == GameOver:
      events.add(%*{
        "t": tick,
        "k": "gameover",
        "winner": (if sim.isDraw: "" else: seatText(sim.winner)),
        "draw": sim.isDraw,
        "reason": reasonText(sim.endReason),
        "endRule": endRuleText(sim.endRule),
        "score": [sim.goals(Azure), sim.goals(Crimson)]
      })

  for seat in Seat:
    if sim.stats[seat].goals > tracker.goals[seat]:
      events.add(%*{
        "t": tick, "k": "goal", "team": seatText(seat),
        "by": (if sim.lastGoalBy >= 0: robotId(int(sim.lastGoalBy)) else: ""),
        "assist": (
          if sim.lastGoalAssist >= 0: %robotId(int(sim.lastGoalAssist))
          else: newJNull()),
        "speed": float(sim.lastGoalSpeed) * 24.0 / 1_000_000.0,
        "score": [sim.goals(Azure), sim.goals(Crimson)]
      })
    if sim.stats[seat].kicks > tracker.kicks[seat]:
      events.add(%*{"t": tick, "k": "kick", "team": seatText(seat),
        "by": (if sim.lastTouch.robot >= 0:
          robotId(int(sim.lastTouch.robot)) else: "")})
    if sim.stats[seat].shots > tracker.shots[seat]:
      events.add(%*{"t": tick, "k": "shot", "team": seatText(seat),
        "onTarget": sim.stats[seat].shotsOnTarget > tracker.onTarget[seat]})
    if sim.stats[seat].saves > tracker.saves[seat]:
      events.add(%*{"t": tick, "k": "save", "team": seatText(seat)})
    if sim.stats[seat].passesCompleted > tracker.passes[seat]:
      events.add(%*{"t": tick, "k": "pass", "team": seatText(seat)})
    if sim.stats[seat].interceptions > tracker.interceptions[seat]:
      events.add(%*{"t": tick, "k": "interception", "team": seatText(seat)})

  # A touch is a new last-toucher, throttled so a scrum cannot flood the feed.
  if sim.lastTouch.robot >= 0 and
      (sim.lastTouch.robot != tracker.lastTouchRobot or
       sim.lastTouch.tick - tracker.lastTouchTick >= 6):
    if sim.lastTouch.tick == int32(tick):
      events.add(%*{"t": tick, "k": "touch",
        "by": robotId(int(sim.lastTouch.robot)),
        "team": seatText(seatOfRobot(int(sim.lastTouch.robot)))})

  # The drop beat comes from the SIM's own record of the drop, not from a
  # stalemate-counter transition: the counter also resets to 0 on the tick the
  # ball leaves the box, so inferring the drop from "the counter was at 239 and
  # is now 0" fired a phantom beat -- a scrubber marker, and a slow-mo trigger,
  # for a drop that never happened.
  if sim.lastDropTick >= 0 and sim.lastDropTick != tracker.lastDropTick:
    events.add(%*{"t": tick, "k": "drop"})

  if sim.phase == Playing and sim.currentTurn() != tracker.turn and
      tracker.turn >= 0:
    events.add(%*{"t": tick, "k": "turn_end", "turn": tracker.turn})

  if sim.lastGoalTick >= 0 and sim.lastGoalTick != tracker.lastGoalTick and
      sim.lastGoalTick == int32(tick):
    events.add(%*{"t": tick, "k": "kickoff",
      "restartForSeat": seatText(Seat(sim.restartSeat and 1))})

  tracker.snapshot(sim)

# --------------------------------------------------------------------------
# Replay chat records -> the non-hashed presentation fields
# --------------------------------------------------------------------------

proc applyRecord*(sim: var SimServer, text: string) =
  ## Folds ONE replay chat record back into the sim's presentation state. This
  ## is the single place the feed is written, so a live broadcast and a replay
  ## tell exactly the same story. Records can never affect the sim: everything
  ## touched here is outside `gameHash`.
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject:
    return
  let kind = node{"k"}.getStr()
  let seatIndex = node{"seat"}.getInt(-1)
  case kind
  of "register":
    if seatIndex in 0 ..< SeatCount:
      let seat = Seat(seatIndex and 1)
      for i in 0 ..< sim.players.len:
        if sim.players[i].seat == seat:
          sim.players[i].policyLabel = node{"policy"}.getStr()
          sim.players[i].policyKind =
            if node{"kind"}.getStr() == "llm": pkLlm else: pkScripted
          sim.players[i].baseline = node{"baseline"}.getStr()
          sim.players[i].registered = true
      sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "register",
        seat: int32(seatIndex),
        text: seatAlias(seat) & " coach: " & node{"kind"}.getStr() & " policy")
  of "directive":
    if seatIndex notin 0 ..< SeatCount:
      return
    let seat = Seat(seatIndex and 1)
    let note = node{"note"}.getStr()
    if note.len > 0:
      sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "note",
        seat: int32(seatIndex), text: seatAlias(seat) & " coach: " & note)
    let robots = node{"robots"}
    if not robots.isNil and robots.kind == JArray:
      for entry in robots:
        let say = entry{"say"}.getStr()
        if say.len > 0:
          sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "say",
            seat: int32(seatIndex),
            text: entry{"id"}.getStr() & ": " & say)
  of "fallback":
    sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "fallback",
      seat: int32(seatIndex),
      text: "coach fell back (" & node{"cause"}.getStr() & ")")
  of "budget_guard":
    sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "fallback",
      seat: -1, text: "coaching budget guard: scripted for the rest")
  else:
    discard
  while sim.feed.len > 64:
    sim.feed.delete(0)

# --------------------------------------------------------------------------
# The chrome frame
# --------------------------------------------------------------------------

proc teamPoliciesJson(sim: SimServer, seat: Seat): JsonNode =
  ## The distinct policy identities seated on one side. Real names, SPECTATOR
  ## side only — the board labels and the LLM view never carry them.
  result = newJArray()
  for player in sim.players:
    if player.seat == seat and player.address.len > 0:
      result.add(%policyName(player.address))
  if result.len == 0:
    let slot = ord(seat)
    if slot < sim.config.slots.len and sim.config.slots[slot].name.len > 0:
      result.add(%sim.config.slots[slot].name)

proc teamStateJson(sim: SimServer, seat: Seat): JsonNode =
  ## One team's scorebug state. `teams.<alias>` carries
  ## {goals, poss, shots, sot, policies} in place of ctf's
  ## {lives, flag, carrier, prog}.
  let
    mine = int(sim.stats[seat].possessionTicks)
    theirs = int(sim.stats[other(seat)].possessionTicks)
    total = max(1, mine + theirs)
  %*{
    "goals": sim.goals(seat),
    "poss": mine * 100 div total,
    "shots": int(sim.stats[seat].shots),
    "sot": int(sim.stats[seat].shotsOnTarget),
    "saves": int(sim.stats[seat].saves),
    "policies": sim.teamPoliciesJson(seat)
  }

proc rosterJson(sim: SimServer): JsonNode =
  ## One entry per CONNECTION (two), keyed by stable join slot. The chrome
  ## reads `name`/`pol` for the scorebug headline; the board never does.
  result = newJArray()
  for player in sim.players:
    result.add(%*{
      "s": int(player.joinOrder),
      "team": seatText(player.seat),
      "name": player.address,
      "pol": policyName(player.address),
      "kind": policyKindText(player.policyKind),
      "alive": true,
      "goals": sim.goals(player.seat),
      "shots": int(sim.stats[player.seat].shots)
    })

proc feedJson(sim: SimServer): JsonNode =
  result = newJArray()
  for line in sim.feed:
    result.add(%*{
      "t": int(line.tick), "k": line.kind,
      "team": (if line.seat >= 0: seatText(Seat(line.seat and 1)) else: ""),
      "text": line.text
    })

proc buildStateJson*(
  sim: SimServer,
  events: JsonNode,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int,
  povSlot: int,
  leadSeries: seq[seq[int]] = @[],
  startTick: int = 0,
  endHoldSeconds: int = 0,
  includeFpMap: bool = false,
  skipLulls: bool = false,
  fastForwarding: bool = false,
  lullSpans: seq[array[2, int]] = @[],
  beatEvents: JsonNode = nil
): string =
  ## Assembles the broadcast chrome frame. Board-derived STATE (score,
  ## possession, roster, verdict) is always present, so even a frame reached by
  ## a seek hydrates the scorebug and end-card with no events.
  var teams = newJObject()
  for seat in Seat:
    teams[seatText(seat)] = sim.teamStateJson(seat)

  var state = %*{
    "t": sim.tickCount,
    "mt": sim.effectiveMaxTicks(),
    "ph": ($sim.phase).toLowerAscii,
    "lob": sim.lobbyStartSecondsRemaining(),
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    "bs": boardRenderScaleFor(MapWidth, MapHeight),
    "pov": povSlot,
    "turn": sim.currentTurn(),
    "turns": sim.turnCount(),
    "teams": teams,
    "roster": sim.rosterJson(),
    "feed": sim.feedJson(),
    "events": (if events.isNil: newJArray() else: events)
  }

  # Full-timeline goal series (sent ONCE per HUD viewer) so the momentum graph
  # draws its whole-timeline shape immediately instead of accumulating to the
  # playhead.
  if leadSeries.len > 0:
    var teamNames = newJArray()
    for seat in Seat:
      teamNames.add(%seatText(seat))
    var points = newJArray()
    for point in leadSeries:
      var row = newJArray()
      for value in point:
        row.add(%value)
      points.add(row)
    state["lead"] = %*{"teams": teamNames, "pts": points}

  if not beatEvents.isNil and beatEvents.len > 0:
    state["beats"] = beatEvents

  if lullSpans.len > 0:
    var spans = newJArray()
    for span in lullSpans:
      spans.add(%*[span[0], span[1]])
    state["lulls"] = spans

  # The end-card is STATE, not an event: present on every game-over frame so a
  # viewer who seeks straight to the end still sees the verdict.
  if sim.phase == GameOver:
    var overTeams = newJObject()
    for seat in Seat:
      overTeams[seatText(seat)] = %*{
        "goals": sim.goals(seat),
        "score": float(sim.scorePermille(seat)) / 1000.0
      }
    state["over"] = %*{
      "winner": (if sim.isDraw: "" else: seatText(sim.winner)),
      "draw": sim.isDraw,
      "reason": reasonText(sim.endReason),
      "endRule": endRuleText(sim.endRule),
      "timeLimit": sim.endRule == erFullTime,
      "teams": overTeams
    }
    if endHoldSeconds > 0:
      state["hold"] = %endHoldSeconds
  discard includeFpMap
  $state
