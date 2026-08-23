## The control layer: legal bits, determinism, the kick gate and the
## boards-escape rule that the round-1 build learned the hard way.

import std/random
import lib/helpers

const LegalBits = ButtonUp or ButtonDown or ButtonLeft or ButtonRight or
  ButtonSelect or ButtonA

proc onlyLegalBits() =
  ## Every intent produces a mask with only legal bits, and never both Up+Down
  ## or Left+Right with a non-zero effect (the compiler emits at most one of
  ## each pair).
  var rng = initRand(4242)
  var sim = playing(testConfig())
  for round in 0 ..< 400:
    sim.pseudoWorld(rng)
    for seat in Seat:
      var directive = emptyDirective(seat)
      for slot in 0 ..< RobotsPerSeat:
        directive.robots[slot] = RobotOrder(
          role: Role(rng.rand(ord(Role.high))),
          intent: Intent(rng.rand(ord(Intent.high))),
          targetX: int32(rng.rand(int(WorldW))),
          targetY: int32(rng.rand(int(WorldH))),
          passTo: (if rng.rand(1) == 0: -1'i32
                   else: int32(firstRobotOf(seat) + rng.rand(2))),
          kick: (if rng.rand(1) == 0: kickAuto else: kickNever),
          say: "")
      sim.activeDirective[seat] = directive
      sim.hasDirective[seat] = true
    let masks = sim.compileMasks(sim.activeDirective)
    for i in 0 ..< RobotCount:
      doAssert (masks[i] and not LegalBits) == 0,
        "illegal bit in mask " & $masks[i] & " for " & robotId(i)
      doAssert (masks[i] and ButtonB) == 0
      doAssert (masks[i] and ButtonC) == 0
      doAssert (masks[i] and ButtonUp) == 0 or (masks[i] and ButtonDown) == 0,
        "Up and Down together on " & robotId(i)
      doAssert (masks[i] and ButtonLeft) == 0 or
        (masks[i] and ButtonRight) == 0,
        "Left and Right together on " & robotId(i)
  report "every intent compiles to legal, non-contradictory bits"

proc pureFunction() =
  ## The same (state, directive) pair always yields the same byte.
  var rng = initRand(7)
  var sim = playing(testConfig())
  for _ in 0 ..< 100:
    sim.pseudoWorld(rng)
    for seat in Seat:
      sim.activeDirective[seat] = sim.formationDirective(seat, 3)
      sim.hasDirective[seat] = true
    let a = sim.compileMasks(sim.activeDirective)
    let b = sim.compileMasks(sim.activeDirective)
    doAssert a == b, "the control layer is not a pure function"
  report "the control layer is a pure function of state and directive"

proc kickNeverIsHonoured() =
  ## `kick: "never"` never sets ButtonA — UNLESS the boards override fired,
  ## which is the one rule a policy cannot switch off.
  var rng = initRand(99)
  var sim = playing(testConfig())
  var sawSuppressed = 0
  for _ in 0 ..< 600:
    sim.pseudoWorld(rng)
    if onBoards(sim.ball.x, sim.ball.y):
      continue                          ## the override's own case, below
    for seat in Seat:
      var directive = sim.formationDirective(seat, 1)
      for slot in 0 ..< RobotsPerSeat:
        directive.robots[slot].kick = kickNever
      sim.activeDirective[seat] = directive
      sim.hasDirective[seat] = true
    let masks = sim.compileMasks(sim.activeDirective)
    for i in 0 ..< RobotCount:
      doAssert (masks[i] and ButtonA) == 0,
        "kick:never still kicked on " & robotId(i)
    inc sawSuppressed
  doAssert sawSuppressed > 100, "not enough off-boards states were sampled"
  report "kick:never suppresses ButtonA off the boards"

proc cooldownRespected() =
  var sim = playing(testConfig())
  sim.ball.x = CentreX
  sim.ball.y = CentreY
  sim.ball.vx = 0
  sim.ball.vy = 0
  for i in 0 ..< RobotCount:
    sim.robots[i].x = CentreX - 800_000'i32
    sim.robots[i].y = CentreY
    sim.robots[i].headingQ = 0
    sim.robots[i].kickCooldown = 0
  for seat in Seat:
    sim.activeDirective[seat] = sim.formationDirective(seat, 0)
    for slot in 0 ..< RobotsPerSeat:
      sim.activeDirective[seat].robots[slot].intent = inShoot
      sim.activeDirective[seat].robots[slot].kick = kickAuto
    sim.hasDirective[seat] = true
  let hot = sim.compileMasks(sim.activeDirective)
  var kicked = false
  for i in 0 ..< RobotCount:
    if (hot[i] and ButtonA) != 0:
      kicked = true
  doAssert kicked, "nobody kicked a ball parked in front of them"
  for i in 0 ..< RobotCount:
    sim.robots[i].kickCooldown = 5
  let cold = sim.compileMasks(sim.activeDirective)
  for i in 0 ..< RobotCount:
    doAssert (cold[i] and ButtonA) == 0,
      "the cooldown was ignored on " & robotId(i)
  report "the kick cooldown is respected"

proc clearingKicksAimUpField() =
  ## For `hold` and `press` -- the two intents that only kick when the ball is
  ## between the robot and its OWN goal -- the kick aim used to be the centre
  ## spot, which for any robot off the halfway line is a different direction
  ## from "away from your own goal". Those are exactly the kicks where getting
  ## the ball up the pitch is the whole point. The aim is now the opponent
  ## goal, as it already was for `chase` and `intercept`.
  for intent in [inHold, inPress]:
    var sim = playing(testConfig())
    for i in 0 ..< RobotCount:
      sim.robots[i].x = CentreX + int32(i) * 400_000'i32
      sim.robots[i].y = 22_000_000'i32
      sim.robots[i].vx = 0
      sim.robots[i].vy = 0
      sim.robots[i].kickCooldown = 0
    # AZ-1 near the top touchline with the ball goal-side of it, so the
    # between-the-robot-and-its-own-goal gate opens. From there the pitch
    # centre and the opponent goal are far apart in brads, which is the whole
    # point: on the halfway line the two aims coincide and prove nothing.
    sim.robots[0].x = 20_000_000'i32
    sim.robots[0].y = 3_000_000'i32
    sim.ball.x = 19_000_000'i32
    sim.ball.y = 3_000_000'i32
    sim.ball.vx = 0
    sim.ball.vy = 0
    let
      toGoal = bradsOfVectorI(targetGoalX(Azure) - sim.robots[0].x,
        CentreY - sim.robots[0].y)
      toCentre = bradsOfVectorI(CentreX - sim.robots[0].x,
        CentreY - sim.robots[0].y)
    var apart = abs(int(toGoal) - int(toCentre))
    if apart > 128:
      apart = 256 - apart
    doAssert apart > 32,
      "this geometry cannot tell the two aims apart (" & $apart & " brads)"

    for seat in Seat:
      var directive = emptyDirective(seat)
      for slot in 0 ..< RobotsPerSeat:
        directive.robots[slot] = RobotOrder(
          role: roleBack, intent: intent,
          targetX: sim.robots[firstRobotOf(seat) + slot].x,
          targetY: sim.robots[firstRobotOf(seat) + slot].y,
          passTo: -1, kick: kickAuto, say: "")
      sim.activeDirective[seat] = directive
      sim.hasDirective[seat] = true

    # Facing the opponent goal: the kick fires.
    sim.robots[0].headingQ = toGoal * 16
    let upField = sim.compileMasks(sim.activeDirective)
    doAssert (upField[0] and ButtonA) != 0,
      intentText(intent) & ": a robot aimed up-field did not clear the ball"
    # Facing the old aim -- the centre spot -- it does not.
    sim.robots[0].headingQ = toCentre * 16
    let atCentre = sim.compileMasks(sim.activeDirective)
    doAssert (atCentre[0] and ButtonA) == 0,
      intentText(intent) & ": the kick still aims at the centre spot"
  report "hold and press clear the ball up-field, not at the centre spot"

proc boardsOverride() =
  ## The boards-escape rule fires inside the band, does NOT fire inside the
  ## goal-mouth corridor, and aims the kick within 32 brads of the escape
  ## point.
  doAssert onBoards(CentreX, 500_000'i32), "a ball on the touchline is on the boards"
  doAssert onBoards(3_000_000'i32, 3_000_000'i32), "a corner ball is on the boards"
  doAssert not onBoards(CentreX, CentreY), "the centre spot is not the boards"
  for y in [GoalYMin, CentreY, GoalYMax]:
    doAssert not onBoards(2_500_000'i32, y),
      "the goal-mouth corridor must never be treated as the boards"

  var sim = playing(testConfig())
  # Ball buried on the bottom touchline, Azure's nearest robot behind it.
  sim.ball.x = 8_000_000'i32
  sim.ball.y = 900_000'i32
  sim.ball.vx = 0
  sim.ball.vy = 0
  for i in 0 ..< RobotCount:
    sim.robots[i].x = CentreX + int32(i) * 500_000'i32
    sim.robots[i].y = 20_000_000'i32
    sim.robots[i].vx = 0
    sim.robots[i].vy = 0
    sim.robots[i].kickCooldown = 0
  sim.robots[0].x = 7_000_000'i32
  sim.robots[0].y = 900_000'i32
  sim.robots[0].headingQ = 0
  for seat in Seat:
    var directive = sim.formationDirective(seat, 0)
    for slot in 0 ..< RobotsPerSeat:
      directive.robots[slot].kick = kickNever   ## the policy says do not kick
    sim.activeDirective[seat] = directive
    sim.hasDirective[seat] = true
  let masks = sim.compileMasks(sim.activeDirective)
  doAssert (masks[0] and ButtonA) != 0,
    "the boards override did not force the kick past kick:never"
  # The escape point is the middle of the pitch, six metres up-field.
  let
    ex = CentreX + 6_000_000'i32 * attackDir(Azure)
    want = bradsOfVectorI(ex - sim.robots[0].x, CentreY - sim.robots[0].y)
    err = abs((((want - sim.robots[0].headingBrads() + 128) mod 256 + 256) mod
      256) - 128)
  doAssert err <= 32,
    "the escape kick is aimed " & $err & " brads off the middle"
  report "the boards-escape rule fires, spares the goal mouth and aims true"

proc cornerIsEscaped() =
  ## A ball parked in a corner with three robots on it is out of the corner
  ## within 120 ticks. This is the round-1 regression, pinned: 6 of 20 scripted
  ## matches used to end 0-0 stuck against the boards.
  var sim = playing(testConfig())
  sim.ball.x = 2_600_000'i32
  sim.ball.y = 700_000'i32
  sim.ball.vx = 0
  sim.ball.vy = 0
  for i in 0 ..< RobotCount:
    sim.robots[i].x = CentreX
    sim.robots[i].y = 20_000_000'i32
    sim.robots[i].vx = 0
    sim.robots[i].vy = 0
  for slot in 0 ..< RobotsPerSeat:
    sim.robots[firstRobotOf(Crimson) + slot].x =
      2_200_000'i32 + int32(slot) * 700_000'i32
    sim.robots[firstRobotOf(Crimson) + slot].y = 1_500_000'i32
  let
    startX = sim.ball.x
    startY = sim.ball.y
  var escaped = false
  for tick in 0 ..< 120:
    let elapsed = sim.tickCount - sim.gameStartTick
    if elapsed mod sim.turnTicks() == 0 or not sim.hasDirective[Azure]:
      for seat in Seat:
        sim.activeDirective[seat] = sim.formationDirective(
          seat, elapsed div sim.turnTicks())
        sim.hasDirective[seat] = true
    sim.stepWith(sim.compileMasks(sim.activeDirective))
    if distI(sim.ball.x - startX, sim.ball.y - startY) > 4_000_000'i32:
      escaped = true
      break
  doAssert escaped,
    "the ball is still buried in the corner after 120 ticks at " &
      $sim.ball.x & "," & $sim.ball.y
  report "a cornered ball is out of the corner within 120 ticks"

proc holdFacesTheBall() =
  ## A `hold` robot that has arrived turns to face the ball instead of
  ## spinning on its target.
  var sim = playing(testConfig())
  sim.ball.x = CentreX
  sim.ball.y = 2_000_000'i32
  for i in 0 ..< RobotCount:
    sim.robots[i].x = 30_000_000'i32
    sim.robots[i].y = 20_000_000'i32
    sim.robots[i].vx = 0
    sim.robots[i].vy = 0
    sim.robots[i].spin = 0
  sim.robots[0].x = 5_000_000'i32
  sim.robots[0].y = CentreY
  sim.robots[0].headingQ = 0                    ## facing east
  var directive = emptyDirective(Azure)
  directive.robots[0] = RobotOrder(role: roleKeeper, intent: inHold,
    targetX: 5_000_000'i32, targetY: CentreY, passTo: -1, kick: kickNever)
  for slot in 1 ..< RobotsPerSeat:
    directive.robots[slot] = RobotOrder(role: roleWing, intent: inHold,
      targetX: 30_000_000'i32, targetY: 20_000_000'i32, passTo: -1,
      kick: kickNever)
  sim.activeDirective[Azure] = directive
  sim.hasDirective[Azure] = true
  sim.activeDirective[Crimson] = sim.formationDirective(Crimson, 0)
  sim.hasDirective[Crimson] = true
  let mask = sim.compileMask(0, directive)
  # The ball is north-north-west of the robot, so it must turn (either bit).
  doAssert (mask and (ButtonLeft or ButtonRight)) != 0,
    "an arrived keeper did not turn toward the ball"
  doAssert (mask and ButtonUp) == 0,
    "an arrived keeper is still driving at its target"
  report "an arrived `hold` robot faces the ball"

when isMainModule:
  echo "test_control"
  onlyLegalBits()
  pureFunction()
  kickNeverIsHonoured()
  cooldownRespected()
  clearingKicksAimUpField()
  boardsOverride()
  cornerIsEscaped()
  holdFacesTheBall()
  echo "test_control: all good"
