## Export complete baseline matches for Metta post-training.
## nim r -d:release --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED] [default|sprint]

import std/[json, os, osproc, strutils]
import bitworld/spriteprotocol
import cogball/[baselines, control, decide, directives, roster, sim]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [default|sprint]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "default"
  if episodes < 10 or firstSeed < 1:
    quit("at least ten episodes and a positive first seed are required", 1)
  if variant notin ["default", "sprint"]:
    quit("variant must be default or sprint", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let revision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject

  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = defaultGameConfig()
    config.update($variantConfig)
    config.seed = seed
    config.validate()
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    discard game.addPlayer("azure-policy", 0, "")
    discard game.addPlayer("crimson-policy", 1, "")
    game.startGame()
    let engine = newTurnEngine(nil)
    for seat in Seat:
      engine.policies[seat] = SeatPolicy(kind: pkScripted,
        baseline: "formation", label: "formation", connected: true)
    var
      rows: seq[string]
      previous = newSeq[InputState](RobotCount)
      lastGoals: array[Seat, int32]
    while game.phase != GameOver:
      let elapsed = game.tickCount - game.gameStartTick
      if elapsed mod game.turnTicks() == 0 or
          not (game.hasDirective[Azure] and game.hasDirective[Crimson]):
        let turn = elapsed div game.turnTicks()
        for seat in Seat:
          let view = engine.seatViewJson(game, seat, turn)
          let directive = game.baselineDirective(seat, "formation", turn)
          let record = directiveJson(game, seat, directive)
          let completion = %*{"note": record["note"], "robots": record["robots"]}
          let parsed = game.parseDirective(seat, completion,
            engine.previous[seat], engine.hasPrevious[seat], directive, turn)
          doAssert parsed.usable
          for slot in 0 ..< RobotsPerSeat:
            doAssert parsed.directive.robots[slot].role == directive.robots[slot].role
            doAssert parsed.directive.robots[slot].intent == directive.robots[slot].intent
          rows.add($(%*{
            "episode_id": "cogball-" & variant & "-" & $seed & "-" & $ord(seat),
            "seed": "cogball-" & variant & "-" & $seed,
            "decision_id": turn * SeatCount + ord(seat),
            "prompt": [
              {"role": "system", "content": SystemPrompt},
              {"role": "user", "content": engine.userMessage(game, seat, turn)}],
            "completion": [{"role": "assistant", "content": $completion}],
            "game": "cogball",
            "action_schema_revision": "cogball-directive-v1"
          }))
          doAssert engine.userMessage(game, seat, turn) == $view
        engine.turn(game, turn, 0)
      let masks = game.compileMasks(game.activeDirective)
      var inputs = newSeq[InputState](RobotCount)
      for i in 0 ..< RobotCount:
        inputs[i] = decodeInputMask(masks[i])
      game.step(inputs, previous)
      previous = inputs
      for seat in Seat:
        if game.stats[seat].goals > lastGoals[seat]:
          lastGoals[seat] = game.stats[seat].goals
          engine.noteGoal(game.tickCount, int(game.lastGoalBy), seat)
    doAssert game.endReason == reasonComplete and rows.len > 0
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "azure_goals": game.goals(Azure), "crimson_goals": game.goals(Crimson),
      "azure_score_permille": game.scorePermille(Azure)})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "cogball",
    "variant": variant,
    "source_revision": revision,
    "teacher": "scripted-formation",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
