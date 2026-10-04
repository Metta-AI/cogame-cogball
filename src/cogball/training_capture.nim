## Game-owned coaching decisions and the three actual robot masks per seat.
import std/[base64, json, options, tables]
import bitworld/decision_trajectory
import decide, roster, sim

type
  CoachExecution* = object
    startTick*: int
    initialHash*: uint64
    masks*: string
    hashes*: seq[string]
  CapturedDecision = object
    id, seat: string
    observation: JsonNode
    decision: TurnDecision
    terminal: bool
  MatchCapture* = ref object
    trajectory*: DecisionTrajectory
    pending: bool
    decisions: array[Seat, TurnDecision]
    physical: array[Seat, CoachExecution]
    staged: seq[CapturedDecision]

proc newMatchCapture*(episodeId, gameVersion, sourceRevision: string,
    seed: int): MatchCapture =
  MatchCapture(trajectory: newDecisionTrajectory(episodeId, "cogball-" & $seed,
    "cogball", gameVersion, sourceRevision))

proc flushTurn*(capture: MatchCapture, endTick: int, terminal = false) =
  if capture.pending:
    for seat in Seat:
      let physical = capture.physical[seat]
      doAssert endTick >= physical.startTick
      doAssert physical.masks.len == (endTick - physical.startTick) * RobotsPerSeat
      doAssert physical.hashes.len == endTick - physical.startTick
      let issued = capture.decisions[seat]
      var observation = copy(issued.observation)
      observation["execution"] = if endTick == physical.startTick: newJNull()
        else: %*{"start_tick": physical.startTick,
          "end_tick": endTick, "tick_hz": TargetFps,
          "control_encoding": "sprite-three-u8",
          "seat_input_masks_b64": encode(physical.masks),
          "initial_hash": $physical.initialHash, "post_tick_hashes": physical.hashes}
      capture.staged.add(CapturedDecision(id: $physical.startTick & "-" & $ord(seat),
        seat: $ord(seat), observation: observation, decision: issued, terminal: terminal))
    capture.pending = false

proc beginTurn*(capture: MatchCapture, engine: TurnEngine, sim: SimServer) =
  capture.flushTurn(sim.tickCount)
  capture.pending = true
  capture.decisions = engine.decisions
  for seat in Seat:
    capture.physical[seat] = CoachExecution(startTick: sim.tickCount,
      initialHash: sim.gameHash())

proc recordTick*(capture: MatchCapture, masks: array[RobotCount, uint8],
    sim: SimServer) =
  if capture.pending:
    for seat in Seat:
      for slot in 0 ..< RobotsPerSeat:
        capture.physical[seat].masks.add(char(masks[firstRobotOf(seat) + slot]))
      capture.physical[seat].hashes.add($sim.gameHash())

proc finishMatch*(capture: MatchCapture, sim: SimServer,
    status: EpisodeStatus, cleanup: JsonNode, updates: Table[string, DecisionAttempt]) =
  capture.flushTurn(sim.tickCount, true)
  for staged in capture.staged:
    var attempts = staged.decision.attempts
    for attempt in attempts.mitems:
      if updates.hasKey(attempt.attemptId):
        let accepted = attempt.accepted
        let parsed = attempt.parsedAction
        let rejection = attempt.rejectionReason
        attempt = updates[attempt.attemptId]
        attempt.accepted = accepted
        attempt.parsedAction = parsed
        attempt.rejectionReason = rejection
    capture.trajectory.recordDecision(staged.id, staged.seat, staged.observation,
      attempts, staged.decision.selectedAttemptId, staged.decision.executedAction,
      staged.decision.status, staged.terminal,
      (if staged.decision.status == asFallback: some("engine-formation") else: none(string)))
  let results = parseJson(sim.playerResultsJson())
  results["player_cleanup"] = cleanup
  results["engine_version"] = %GameVersion
  var participants = newJObject()
  for seat in Seat:
    participants[$ord(seat)] = %*{"score": results["scores"][ord(seat)],
      "goals": sim.goals(seat), "win": sim.seatWon(seat)}
  capture.trajectory.finish(status, results,
    if status == esCompleted: participants else: newJNull())
