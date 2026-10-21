## Export complete baseline matches for Metta post-training.
## nim r -d:release --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED] [default|sprint]

import std/[json, os, osproc, strutils, tables]
import bitworld/[spriteprotocol, decision_trajectory]
import cogball/[control, decide, roster, sim, training_capture, prompts]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [default|sprint [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "default"
  let initialSelection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if initialSelection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out prompt variants are evaluation-only")
  if episodes < 10 or firstSeed < 1:
    quit("at least ten episodes and a positive first seed are required", 1)
  if variant notin ["default", "sprint"]:
    quit("variant must be default or sprint", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit the qualified source before generating a pinned training corpus"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject

  var
    completeEpisodes: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var selection = initialSelection
    if selection.variant == pvMixed:
      selection.seed += seed - firstSeed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config.seed = seed
    config.validate()
    var game = initSimServer(config)
    game.gameEventLoggingEnabled = false
    discard game.addPlayer("azure-policy", 0, "")
    discard game.addPlayer("crimson-policy", 1, "")
    while game.phase == Lobby:
      game.step(default(array[RobotCount, InputState]),
        default(array[RobotCount, InputState]))
    let engine = newTurnEngine(selection, nil)
    for seat in Seat:
      engine.policies[seat] = SeatPolicy(kind: pkScripted,
        baseline: "formation", label: "formation", connected: true)
    let capture = newMatchCapture("cogball-" & variant & "-" & $seed & "-" &
      $selection.selectedVariant & "-" & $selection.seed,
      "source-engine-1", revision, seed)
    var
      decisions = 0
      previous = newSeq[InputState](RobotCount)
      lastGoals: array[Seat, int32]
    while game.phase != GameOver:
      let elapsed = game.tickCount - game.gameStartTick
      if elapsed mod game.turnTicks() == 0 or
          not (game.hasDirective[Azure] and game.hasDirective[Crimson]):
        let turn = elapsed div game.turnTicks()
        engine.turn(game, turn, 0)
        capture.beginTurn(engine, game)
        decisions += SeatCount
      let masks = game.compileMasks(game.activeDirective)
      var inputs = newSeq[InputState](RobotCount)
      for i in 0 ..< RobotCount:
        inputs[i] = decodeInputMask(masks[i])
      game.step(inputs, previous)
      capture.recordTick(masks, game)
      previous = inputs
      for seat in Seat:
        if game.stats[seat].goals > lastGoals[seat]:
          lastGoals[seat] = game.stats[seat].goals
          engine.noteGoal(game.tickCount, int(game.lastGoalBy), seat)
    doAssert game.endReason == reasonComplete and decisions > 0
    capture.finishMatch(game, esCompleted, newJObject(), initTable[string, DecisionAttempt]())
    completeEpisodes.add(capture.trajectory.eventsJsonl())
    runs.add(%*{"seed": seed, "decisions": decisions,
      "prompt_selection": selection.selectionMetadata(),
      "azure_goals": game.goals(Azure), "crimson_goals": game.goals(Crimson),
      "azure_score_permille": game.scorePermille(Azure)})
  writePrivate(output / "trajectories.jsonl", completeEpisodes.join(""))
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "cogball",
    "variant": variant,
    "source_revision": revision,
    "teacher": "scripted-formation",
    "prompt_selection": initialSelection.selectionMetadata(),
    "game_version": "source-engine-1",
    "engine_version": GameVersion,
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "inference_mode": "text_action",
    "runs": runs
  }) & "\n")
  echo "complete games=", episodes
