## Numeric bridge over Cogball's hosted coach view and directive controller.
## nim c -d:release --path:src -o:/tmp/cogball-train-bridge tools/train_bridge.nim

import std/[hashes, json, os]
import bitworld/spriteprotocol
import cogball/[baselines, control, decide, directives, roster, sim]

const
  IntentsPerRobot = ord(Intent.high) + 1
  CandidateCount = 2 + IntentsPerRobot * IntentsPerRobot * IntentsPerRobot

var
  game: SimServer
  engine: TurnEngine
  views: array[Seat, JsonNode]
  chosen: array[Seat, Directive]
  decisionId: int
  actingSeat: Seat
  variant: string
  manifestPath: string

proc values(view: JsonNode): JsonNode =
  result = newJArray()
  for name in ["default", "sprint"]:
    result.add(%(if variant == name: 1 else: 0))
  for name in ["turn", "of"]: result.add(view[name])
  for name in ["played_s", "left_s"]: result.add(view["clock"][name])
  for name in ["you", "them"]: result.add(view["score"][name])
  let ball = view["ball"]
  for field in ["pos", "vel"]:
    for number in ball[field]: result.add(number)
  result.add(ball["speed"])
  let possession = ball["possession"].getStr()
  var ownPossession = false
  for robot in view["your_robots"]:
    if robot["id"].getStr() == possession: ownPossession = true
  for condition in [possession == "loose", ownPossession,
      possession != "loose" and not ownPossession]:
    result.add(%(if condition: 1 else: 0))
  for name in ["in_your_half", "on_boards"]:
    result.add(%(if ball[name].getBool(): 1 else: 0))
  for side in ["your_robots", "their_robots"]:
    doAssert view[side].len == RobotsPerSeat
    for robot in view[side]:
      for field in ["pos", "vel", "facing"]:
        for number in robot[field]: result.add(number)
      for field in ["speed", "dist_to_ball"]: result.add(robot[field])
      if side == "your_robots":
        result.add(%(if robot["kick_ready"].getBool(): 1 else: 0))
        for role in Role:
          result.add(%(if robot.hasKey("last_role") and
            robot["last_role"].getStr() == roleText(role): 1 else: 0))
  for name in ["your_kicks", "their_kicks", "your_shots", "their_shots",
      "possession_pct_you"]:
    result.add(view["last_turn"][name])
  result.add(%view["last_turn"]["goals"].len)

proc candidates(): JsonNode =
  result = newJArray()
  for choice in 0 ..< CandidateCount:
    result.add(%*{"choice": choice})

proc currentDecision(): JsonNode =
  let view = views[actingSeat]
  %*{"kind": "decision", "game": "cogball", "decision_id": decisionId,
    "seat": ord(actingSeat), "engine_seat": ord(actingSeat),
    "turn": game.currentTurn(), "semantic_view": view, "inbox": [],
    "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": $view}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0,
        "maximum": CandidateCount - 1}}, "required": ["choice"]},
    "typed_question": newJNull()}

proc captureViews() =
  let turn = game.currentTurn()
  for seat in Seat:
    views[seat] = engine.seatViewJson(game, seat, turn)

proc reset(command: JsonNode): JsonNode =
  doAssert command["players"].getInt() == SeatCount
  let manifest = parseFile(manifestPath)
  var selected = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: selected = entry["game_config"]
  doAssert selected.kind == JObject
  var config = defaultGameConfig()
  config.update($selected)
  config.seed = int(hash(command["seed"].getStr()) and hash(high(int)))
  config.validate()
  game = initSimServer(config)
  game.gameEventLoggingEnabled = false
  discard game.addPlayer("azure-policy", 0, "")
  discard game.addPlayer("crimson-policy", 1, "")
  game.startGame()
  engine = newTurnEngine(nil, nil)
  for seat in Seat:
    engine.policies[seat] = SeatPolicy(kind: pkScripted,
      baseline: "formation", label: "formation", connected: true)
  captureViews()
  decisionId = 0
  actingSeat = Azure
  currentDecision()

proc directiveFor(choice: int, seat: Seat): Directive =
  let turn = game.currentTurn()
  let baseline = game.baselineDirective(seat,
    if choice == 1: "swarm" else: "formation", turn)
  let record = directiveJson(game, seat, baseline)
  var reply = %*{"note": record["note"], "robots": record["robots"]}
  if choice >= 2:
    var code = choice - 2
    for slot in 0 ..< RobotsPerSeat:
      reply["robots"][slot]["intent"] = %intentText(Intent(code mod IntentsPerRobot))
      code = code div IntentsPerRobot
  let parsed = game.parseDirective(seat, reply, engine.previous[seat],
    engine.hasPrevious[seat], baseline, turn)
  doAssert parsed.usable
  parsed.directive

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(command["response"].getStr())
  let choice = action["choice"].getInt()
  doAssert choice in 0 ..< CandidateCount
  chosen[actingSeat] = directiveFor(choice, actingSeat)
  inc decisionId
  if actingSeat == Azure:
    actingSeat = Crimson
    return %*{"kind": "accepted", "action": action,
      "observation": currentDecision()}
  for seat in Seat:
    game.activeDirective[seat] = chosen[seat]
    game.hasDirective[seat] = true
    engine.previous[seat] = chosen[seat]
    engine.hasPrevious[seat] = true
    engine.lastStats[seat] = game.stats[seat]
  engine.lastGoals.setLen(0)
  var
    previous = newSeq[InputState](RobotCount)
    lastGoals: array[Seat, int32]
  for seat in Seat: lastGoals[seat] = game.stats[seat].goals
  for tick in 0 ..< game.turnTicks():
    if game.phase == GameOver: break
    let masks = game.compileMasks(game.activeDirective)
    var inputs = newSeq[InputState](RobotCount)
    for i in 0 ..< RobotCount: inputs[i] = decodeInputMask(masks[i])
    game.step(inputs, previous)
    previous = inputs
    for seat in Seat:
      if game.stats[seat].goals > lastGoals[seat]:
        lastGoals[seat] = game.stats[seat].goals
        engine.noteGoal(game.tickCount, int(game.lastGoalBy), seat)
  let observation = if game.phase == GameOver:
    %*{"kind": "terminal",
      "scores": {"0": game.scorePermille(Azure),
                 "1": game.scorePermille(Crimson)},
      "utilities": {"0": 2.0 * float(game.scorePermille(Azure)) / 1000.0 - 1.0,
                    "1": 2.0 * float(game.scorePermille(Crimson)) / 1000.0 - 1.0}}
    else:
      captureViews()
      actingSeat = Azure
      currentDecision()
  %*{"kind": "accepted", "action": action, "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2: quit("usage: cogball-train-bridge MANIFEST [default|sprint]", 1)
  manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in ["default", "sprint"]
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": %*{"decision_id": decisionId,
        "values": values(views[actingSeat]), "actions": candidates()}
      of "teacher": %*{"response": $(%*{"choice": 0})}
      of "step": step(command)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
