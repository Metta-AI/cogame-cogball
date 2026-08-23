## The grid harness behind the scripted baselines' tuning constants.
##
## `baselines.nim`'s constants are `{.intdefine.}` so they can be swept from
## the command line without editing the source. This is the runner that does
## the sweeping: it plays `formation` against `swarm` over a seed list, BOTH
## SIDES PLAYED (each seed is played once with formation as Azure and once with
## formation as Crimson, so a side bias cannot be read as a tuning win), and
## prints one summary line plus the constants it was built with.
##
## It drives the REAL control layer and the REAL sim, exactly as the server
## does, minus the sockets and the LLM — so a number that wins here wins in a
## match.
##
##   nim c -d:release --out:bin/tune_baselines tools/tune_baselines.nim
##   bin/tune_baselines                      # the default 24-seed sweep
##   bin/tune_baselines 4800 1 7919 15838    # maxTicks, then the seeds
##
## `tools/tune_baselines.sh` wraps this in the recompile loop that varies one
## constant at a time; `docs/tuning/baseline-grid.md` records what it found.

import
  std/[os, strutils],
  bitworld/spriteprotocol,
  cogball/[baselines, control, roster, sim]

const DefaultSeeds = [
  ## Twenty-four seeds, so a default run is 48 matches (both sides played) --
  ## the sample size the tuning notes in baselines.nim quote. Fixed and
  ## committed, because a sweep whose seeds move between runs compares nothing.
  1, 7919, 15838, 23757, 31676, 39595, 47514, 55433,
  63352, 71271, 79190, 87109, 95028, 102947, 110866, 118785,
  126704, 134623, 142542, 150461, 158380, 166299, 174218, 679961
]

type MatchResult = object
  goals: array[Seat, int]
  ticks: int
  rule: EndRule

proc playMatch(seed, maxTicks: int, azure, crimson: string): MatchResult =
  ## One whole episode on the scripted layer, through the same control layer
  ## the server compiles masks with.
  var config = defaultGameConfig()
  config.seed = seed
  config.maxTicks = maxTicks
  config.minPlayers = 2
  config.startWaitTicks = 1
  config.gameOverTicks = 1
  config.slots = @[
    PlayerSlotConfig(name: "azure", token: "t0", team: Azure, hasTeam: true),
    PlayerSlotConfig(name: "crimson", token: "t1", team: Crimson, hasTeam: true)
  ]
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  discard sim.addPlayer("azure", 0, "t0")
  discard sim.addPlayer("crimson", 1, "t1")
  var prev = newSeq[InputState](RobotCount)
  var guard = 0
  while sim.phase != GameOver and guard < maxTicks * 3 + 5000:
    inc guard
    if sim.phase == Playing:
      let elapsed = sim.tickCount - sim.gameStartTick
      if elapsed mod sim.turnTicks() == 0 or
          not (sim.hasDirective[Azure] and sim.hasDirective[Crimson]):
        let turn = elapsed div sim.turnTicks()
        sim.activeDirective[Azure] = sim.baselineDirective(Azure, azure, turn)
        sim.activeDirective[Crimson] =
          sim.baselineDirective(Crimson, crimson, turn)
        for seat in Seat:
          sim.hasDirective[seat] = true
    let masks = sim.compileMasks(sim.activeDirective)
    var inputs = newSeq[InputState](RobotCount)
    for i in 0 ..< RobotCount:
      inputs[i] = decodeInputMask(masks[i])
    sim.step(inputs, prev)
    prev = inputs
  for seat in Seat:
    result.goals[seat] = sim.goals(seat)
  result.ticks = sim.tickCount
  result.rule = sim.endRule

when isMainModule:
  var
    maxTicks = DefaultMaxTicks
    seeds: seq[int]
  let args = commandLineParams()
  if args.len > 0:
    maxTicks = parseInt(args[0])
    for i in 1 ..< args.len:
      seeds.add(parseInt(args[i]))
  if seeds.len == 0:
    for seed in DefaultSeeds:
      seeds.add(seed)

  var
    wins = 0
    draws = 0
    losses = 0
    goalsFor = 0
    goalsAgainst = 0
    goalless = 0
  for seed in seeds:
    # Both sides played: formation as Azure, then formation as Crimson.
    for formationSeat in Seat:
      let outcome =
        if formationSeat == Azure:
          playMatch(seed, maxTicks, "formation", "swarm")
        else:
          playMatch(seed, maxTicks, "swarm", "formation")
      let
        mine = outcome.goals[formationSeat]
        theirs = outcome.goals[other(formationSeat)]
      goalsFor += mine
      goalsAgainst += theirs
      if mine + theirs == 0:
        inc goalless
      if mine > theirs: inc wins
      elif mine == theirs: inc draws
      else: inc losses

  let matches = 2 * seeds.len
  echo "KeeperArc=", KeeperArc,
    " KeeperYSpan=", KeeperYSpan,
    " StrikerRange=", StrikerRange,
    " BackPull=", BackPull,
    " WingLead=", WingLead,
    " WingWide=", WingWide,
    " SupportAlwaysRuns=", SupportAlwaysRuns
  echo "matches=", matches,
    " formation W-D-L=", wins, "-", draws, "-", losses,
    " goals=", goalsFor, ":", goalsAgainst,
    " gd=", goalsFor - goalsAgainst,
    " goalless=", goalless,
    " score=", (2 * wins + draws), "/", 2 * matches
