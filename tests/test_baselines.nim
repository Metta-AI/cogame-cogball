## Bounded-orders / legality assertion on the scripted baselines, plus the
## round-1 corner regression, pinned.

import std/[random, unicode]
import lib/helpers

proc validate(sim: SimServer, seat: Seat, directive: Directive, what: string) =
  ## The reply schema, asserted against a produced directive. A baseline that
  ## cannot satisfy it is not a comparable policy.
  doAssert directive.note.runeLen <= MaxNoteRunes,
    what & ": note is " & $directive.note.runeLen & " runes"
  doAssert isValidUtf8(directive.note), what & ": note is not valid UTF-8"
  var seen: array[RobotsPerSeat, bool]
  for slot in 0 ..< RobotsPerSeat:
    let
      order = directive.robots[slot]
      index = firstRobotOf(seat) + slot
    doAssert not seen[slot]
    seen[slot] = true
    doAssert ord(order.role) in 0 .. ord(Role.high), what & ": bad role"
    doAssert ord(order.intent) in 0 .. ord(Intent.high), what & ": bad intent"
    doAssert ord(order.kick) in 0 .. ord(KickMode.high), what & ": bad kick"
    doAssert order.targetX >= CentreX - 20_000_000'i32 and
      order.targetX <= CentreX + 20_000_000'i32,
      what & ": target x " & $order.targetX & " is off the pitch"
    doAssert order.targetY >= CentreY - 12_500_000'i32 and
      order.targetY <= CentreY + 12_500_000'i32,
      what & ": target y " & $order.targetY & " is off the pitch"
    if order.passTo >= 0:
      doAssert seatOfRobot(int(order.passTo)) == seat,
        what & ": pass_to is an opponent"
      doAssert order.passTo != int32(index), what & ": pass_to is self"
    doAssert order.say.runeLen <= MaxSayRunes,
      what & ": say is " & $order.say.runeLen & " runes"
    doAssert isValidUtf8(order.say), what & ": say is not valid UTF-8"

proc boundedOrders() =
  ## 500 pseudo-random world states x both baselines: every emitted directive
  ## validates, and every compiled mask has only legal bits.
  const LegalBits = ButtonUp or ButtonDown or ButtonLeft or ButtonRight or
    ButtonSelect or ButtonA
  var rng = initRand(0xBA5E)
  var sim = playing(testConfig())
  for round in 0 ..< 500:
    sim.pseudoWorld(rng)
    for name in ["formation", "swarm"]:
      for seat in Seat:
        let directive = sim.baselineDirective(seat, name, round)
        sim.validate(seat, directive,
          name & " seat " & seatAlias(seat) & " round " & $round)
        sim.activeDirective[seat] = directive
        sim.hasDirective[seat] = true
      let masks = sim.compileMasks(sim.activeDirective)
      for i in 0 ..< RobotCount:
        doAssert (masks[i] and not LegalBits) == 0,
          name & ": illegal bit on " & robotId(i)
  report "500 states x both baselines produce legal, bounded orders"

proc unknownBaselineIsFormation() =
  var sim = playing(testConfig())
  let fallback = sim.baselineDirective(Azure, "not-a-baseline", 0)
  let formation = sim.formationDirective(Azure, 0)
  doAssert fallback.note == formation.note
  for slot in 0 ..< RobotsPerSeat:
    doAssert fallback.robots[slot].intent == formation.robots[slot].intent
  report "an unknown baseline name plays `formation`"

proc exactlyOneKeeper() =
  ## `formation` always fields exactly one keeper, and it is the robot nearest
  ## its own goal.
  var rng = initRand(11)
  var sim = playing(testConfig())
  for _ in 0 ..< 200:
    sim.pseudoWorld(rng)
    for seat in Seat:
      let directive = sim.formationDirective(seat, 0)
      var keepers = 0
      var keeperSlot = -1
      for slot in 0 ..< RobotsPerSeat:
        if directive.robots[slot].role == roleKeeper:
          inc keepers
          keeperSlot = slot
      doAssert keepers == 1,
        "formation fielded " & $keepers & " keepers for " & seatAlias(seat)
      let own = ownGoalX(seat)
      for slot in 0 ..< RobotsPerSeat:
        if slot == keeperSlot:
          continue
        doAssert abs(int64(sim.robots[firstRobotOf(seat) + keeperSlot].x) -
            int64(own)) <=
          abs(int64(sim.robots[firstRobotOf(seat) + slot].x) - int64(own)),
          "the keeper is not the deepest robot"
  report "`formation` always fields exactly one keeper, the deepest robot"

proc swarmRolesAreFixed() =
  ## `swarm` reports striker/striker/back: the deepest robot is the `back`
  ## whatever the ball is doing. The role used to flip to striker whenever the
  ## ball crossed into the opponent half, so the seat view's `last_role` and
  ## the feed described a robot that changed identity twice a minute while
  ## doing the same job.
  var rng = initRand(0x5A11)
  var sim = playing(testConfig())
  var sawBothHalves: array[2, bool]
  for _ in 0 ..< 200:
    sim.pseudoWorld(rng)
    for seat in Seat:
      let
        directive = sim.swarmDirective(seat, 0)
        deepest = sim.deepestRobot(seat) - firstRobotOf(seat)
      sawBothHalves[ord(sim.ballInOwnHalf(seat))] = true
      var backs = 0
      for slot in 0 ..< RobotsPerSeat:
        let role = directive.robots[slot].role
        if slot == deepest:
          doAssert role == roleBack,
            "swarm's deepest robot reported " & roleText(role) & ", not back"
          inc backs
        else:
          doAssert role == roleStriker,
            "swarm reported " & roleText(role) & " for a chasing robot"
      doAssert backs == 1, "swarm fielded " & $backs & " backs"
  doAssert sawBothHalves[0] and sawBothHalves[1],
    "the sweep never saw the ball in both halves, so it proved nothing"
  report "swarm's roles are striker/striker/back in both halves"

proc formationBeatsSwarm() =
  ## The pinned match: at seed 679961 a formation-vs-swarm episode completes,
  ## formation wins, and it is NOT 0-0 — the round-1 corner regression, where
  ## 6 of 20 scripted matches ended goalless stuck against the boards.
  let result = runScriptedMatch(testConfig(seed = 679961), "formation", "swarm")
  doAssert result.reason == reasonComplete,
    "the match did not complete: " & reasonText(result.reason)
  doAssert result.rule in {erFullTime, erMercy},
    "unexpected end rule " & endRuleText(result.rule)
  doAssert result.goals[Azure] + result.goals[Crimson] > 0,
    "the match ended 0-0 — the corner regression is back"
  doAssert result.goals[Azure] > result.goals[Crimson],
    "formation lost to swarm at the pinned seed: " &
      $result.goals[Azure] & "-" & $result.goals[Crimson]
  report "formation beats swarm at seed 679961, and not 0-0 (" &
    $result.goals[Azure] & "-" & $result.goals[Crimson] & ")"

proc goalsHappenAcrossSeeds() =
  ## Goals are not a fluke of one seed: a walled 3v3 pitch that produces
  ## goalless matches is not a game.
  var goalless = 0
  var total = 0
  for seed in [1, 7919, 15838, 23757, 31676, 679961]:
    let result = runScriptedMatch(testConfig(seed = seed), "formation", "swarm")
    inc total
    if result.goals[Azure] + result.goals[Crimson] == 0:
      inc goalless
  doAssert goalless == 0,
    $goalless & " of " & $total & " scripted matches ended goalless"
  report "no scripted match across six seeds ends goalless"

when isMainModule:
  echo "test_baselines"
  boundedOrders()
  unknownBaselineIsFormation()
  exactlyOneKeeper()
  swarmRolesAreFixed()
  formationBeatsSwarm()
  goalsHappenAcrossSeeds()
  echo "test_baselines: all good"
