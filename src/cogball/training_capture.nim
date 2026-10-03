## Game-owned coaching decisions and the three actual robot masks per seat.
import std/[base64, json, options]
import bitworld/decision_trajectory
import decide, roster, sim

type
  CoachExecution* = object
    startTick*: int
    initialHash*: uint64
    masks*: string
    hashes*: seq[string]
  MatchCapture* = ref object
    trajectory*: DecisionTrajectory
    pending: bool
    decisions: array[Seat, TurnDecision]
    physical: array[Seat, CoachExecution]

proc newMatchCapture*(episodeId, gameVersion, sourceRevision: string,
    seed: int): MatchCapture =
  MatchCapture(trajectory: newDecisionTrajectory(episodeId, "cogball-" & $seed,
    "cogball", gameVersion, sourceRevision))

proc flushTurn*(capture: MatchCapture, endTick: int, terminal = false) =
  if capture.pending:
    for seat in Seat:
      let physical = capture.physical[seat]
      doAssert endTick > physical.startTick
      doAssert physical.masks.len == (endTick - physical.startTick) * RobotsPerSeat
      doAssert physical.hashes.len == endTick - physical.startTick
      let issued = capture.decisions[seat]
      var observation = copy(issued.observation)
      observation["execution"] = %*{"start_tick": physical.startTick,
        "end_tick": endTick, "tick_hz": TargetFps,
        "control_encoding": "sprite-three-u8",
        "seat_input_masks_b64": encode(physical.masks),
        "initial_hash": $physical.initialHash, "post_tick_hashes": physical.hashes}
      capture.trajectory.recordDecision($physical.startTick & "-" & $ord(seat),
        $ord(seat), observation, issued.attempts, issued.selectedAttemptId,
        issued.executedAction, issued.status, terminal,
        (if issued.status == asFallback: some("engine-formation") else: none(string)))
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

proc finishMatch*(capture: MatchCapture, sim: SimServer) =
  capture.flushTurn(sim.tickCount, true)
  let status = case sim.endReason
    of reasonComplete: esCompleted
    of reasonDeadline: esTruncated
    of reasonFault: esFailed
  let results = parseJson(sim.playerResultsJson())
  var participants = newJObject()
  for seat in Seat:
    participants[$ord(seat)] = %*{"score": results["scores"][ord(seat)],
      "goals": sim.goals(seat), "win": sim.seatWon(seat)}
  capture.trajectory.finish(status, results, participants)
