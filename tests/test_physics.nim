## Sim unit tests: the integer physics, the kick model, the restarts.
##
## These are the assertions that keep `sim.nim` honest about the things the
## design pins numerically. A failure here is a rules change, not a flake.

import std/math
import lib/helpers

proc ballDrag(v: int32): int32 =
  ## One substep of ball drag, mirroring sim.integrateBall's single line
  ## (`v -= v * BallDragNum div 1024`, taken in int64 and truncated toward
  ## zero). Spelled out here so the bounce and kick assertions below can be
  ## EXACT instead of carrying a tolerance for "one substep of drag happened".
  v - int32((int64(v) * int64(BallDragNum)) div 1024)

proc robotDrag(v: int32): int32 =
  ## The same for sim.integrateRobots' linear drag, for a robot with no thrust,
  ## no turn and no lateral component (the kick-reaction case below).
  v - int32((int64(v) * int64(RobotDragNum)) div 1024)

proc noTunnelling() =
  ## A ball fired at BallMaxSpeed into a wall for 600 ticks never leaves the
  ## arena. Four substeps of 1/96 s move a 25 m/s ball at most 0.26 m — less
  ## than its own 0.70 m diameter — which is why nothing can pass through.
  for angle in 0 ..< 16:
    var sim = playing(testConfig())
    # Park every robot in a corner so only the ball is in play.
    for i in 0 ..< RobotCount:
      sim.robots[i].x = CentreX + int32((i - 3) * 300_000)
      sim.robots[i].y = 1_000_000'i32
      sim.robots[i].vx = 0
      sim.robots[i].vy = 0
    sim.ball.x = CentreX
    sim.ball.y = CentreY
    let b = int32(angle * 16)
    sim.ball.vx = int32((int64(BallMaxSpeed) * int64(cosQ12(b))) div 4096)
    sim.ball.vy = int32((int64(BallMaxSpeed) * int64(-sinQ12(b))) div 4096)
    for _ in 0 ..< 600:
      if sim.phase != Playing:
        break
      sim.stepIdle()
      doAssert inPitch(sim.ball.x, sim.ball.y),
        "ball left the arena at angle " & $angle & ": " &
          $sim.ball.x & "," & $sim.ball.y
      doAssert sim.endRule != erSimFault, "physics guard tripped"
  report "a max-speed ball never tunnels out of the arena"

proc wallRestitution() =
  ## The touchline reflects the normal component at 80 %. Asserted EXACTLY, to
  ## the fixed-point quantum: the tick is four substeps of
  ## drag-then-integrate, the bounce lands in the substep the ball crosses the
  ## line, and the remaining substeps are drag only. Every one of those steps
  ## is reproduced here, so the assertion is equality and a one-unit change in
  ## BallDragNum or BallWallRestitutionPct fails it.
  var sim = playing(testConfig())
  for i in 0 ..< RobotCount:
    sim.robots[i].x = CentreX
    sim.robots[i].y = CentreY + 8_000_000'i32
  sim.ball.x = CentreX
  sim.ball.y = 500_000'i32
  sim.ball.vx = 0
  sim.ball.vy = -400_000'i32

  # Model the tick: y is above the floor at 500 000 um, the wall clamps the
  # centre to BallRadius, and the bounce happens in whichever substep crosses.
  var v = sim.ball.vy
  var y = sim.ball.y
  var bounced = false
  for _ in 0 ..< Substeps:
    v = ballDrag(v)
    y += v div Substeps
    if not bounced and y < BallRadius:
      y = BallRadius
      v = -int32((int64(v) * int64(BallWallRestitutionPct)) div 100)
      bounced = true
  doAssert bounced, "the model says the ball never reached the touchline"

  sim.stepIdle()
  doAssert sim.ball.vy > 0, "the ball did not bounce off the touchline"
  doAssert sim.ball.vy == v,
    "wall bounce speed " & $sim.ball.vy & " != the analytic " & $v
  doAssert sim.ball.y == y,
    "the ball rested at " & $sim.ball.y & " != the analytic " & $y
  doAssert sim.ball.vx == 0, "a normal-only bounce moved the tangential axis"
  report "wall restitution reproduces the analytic bounce exactly"

proc robotPairSymmetry() =
  ## Robot-robot resolution is symmetric under swapping the indices and
  ## conserves momentum EXACTLY (Nim's div truncates toward zero, so the
  ## impulse is equal and opposite by construction).
  var sim = playing(testConfig())
  for i in 0 ..< RobotCount:
    sim.robots[i].x = CentreX + int32(i * 8_000_000) div 4
    sim.robots[i].y = 2_000_000'i32
    sim.robots[i].vx = 0
    sim.robots[i].vy = 0
  sim.ball.x = 20_000_000'i32
  sim.ball.y = 23_000_000'i32
  sim.robots[0].x = CentreX - 500_000'i32
  sim.robots[0].y = CentreY
  sim.robots[0].vx = 200_000'i32
  sim.robots[1].x = CentreX + 500_000'i32
  sim.robots[1].y = CentreY
  sim.robots[1].vx = -200_000'i32
  let sumBefore = int64(sim.robots[0].vx) + int64(sim.robots[1].vx)
  sim.stepIdle()
  let sumAfter = int64(sim.robots[0].vx) + int64(sim.robots[1].vx)
  doAssert sumBefore == 0
  doAssert sumAfter == 0, "momentum was not conserved: " & $sumAfter
  doAssert sim.robots[0].vx < 0 and sim.robots[1].vx > 0,
    "the pair did not separate"
  doAssert sim.robots[0].vx == -sim.robots[1].vx,
    "the resolution is not symmetric under index swap"
  report "robot-robot resolution is symmetric and conserves momentum"

proc kickModel() =
  ## The kick sets the along-heading ball speed to exactly
  ## max(vpar, 0) + KickImpulse and applies the mass-ratio reaction.
  var sim = playing(testConfig())
  for i in 0 ..< RobotCount:
    sim.robots[i].x = 6_000_000'i32 + int32(i) * 400_000'i32
    sim.robots[i].y = 23_000_000'i32
    sim.robots[i].vx = 0
    sim.robots[i].vy = 0
    sim.robots[i].headingQ = 0
    sim.robots[i].kickCooldown = 1
  sim.robots[0].x = CentreX
  sim.robots[0].y = CentreY
  sim.robots[0].kickCooldown = 0
  sim.ball.x = CentreX + 1_000_000'i32
  sim.ball.y = CentreY
  sim.ball.vx = 0
  sim.ball.vy = 0
  var masks: array[RobotCount, uint8]
  masks[0] = ButtonA
  sim.stepWith(masks)
  doAssert sim.robots[0].kickCooldown == KickCooldownTicks - 1,
    "the cooldown was not armed: " & $sim.robots[0].kickCooldown
  # The kick runs BEFORE the four substeps, so both bodies then take four
  # substeps of drag and nothing else: the ball is clear of the robot (they are
  # 1.0 m apart against a 0.9 m contact span, and the kick drives them apart)
  # and neither reaches a wall. Both assertions are therefore EXACT.
  var ball = int32(KickImpulse)
  var reaction = -int32(
    (int64(BallMassG) * int64(KickImpulse)) div int64(RobotMassG))
  for _ in 0 ..< Substeps:
    ball = ballDrag(ball)
    reaction = robotDrag(reaction)
  doAssert sim.ball.vx == ball,
    "the kick gave the ball " & $sim.ball.vx & ", not the analytic " & $ball
  doAssert sim.ball.vy == 0, "a head-on kick moved the ball off its axis"
  doAssert sim.robots[0].vx == reaction,
    "the reaction is " & $sim.robots[0].vx & ", not the mass-ratio " &
      $reaction
  doAssert reaction < 0, "the robot took no reaction"
  report "the kick applies the exact impulse and the mass-ratio reaction"

proc kickArc() =
  ## The +-60 degree frontal arc is exact: a ball behind the robot is not
  ## kickable however close it is.
  var sim = playing(testConfig())
  for i in 0 ..< RobotCount:
    sim.robots[i].x = 6_000_000'i32 + int32(i) * 400_000'i32
    sim.robots[i].y = 23_000_000'i32
    sim.robots[i].kickCooldown = 1
  sim.robots[0].x = CentreX
  sim.robots[0].y = CentreY
  sim.robots[0].headingQ = 0                 ## facing east
  sim.robots[0].kickCooldown = 0
  sim.ball.x = CentreX - 1_000_000'i32       ## directly behind
  sim.ball.y = CentreY
  var masks: array[RobotCount, uint8]
  masks[0] = ButtonA
  sim.stepWith(masks)
  doAssert sim.robots[0].kickCooldown == 0,
    "a ball behind the robot was kicked"
  report "the frontal arc rejects a ball behind the robot"

proc goalPlane() =
  ## The goal test fires on the exact plane crossing, and not one tick early.
  var sim = playing(testConfig())
  for i in 0 ..< RobotCount:
    sim.robots[i].x = CentreX + int32(i) * 400_000'i32
    sim.robots[i].y = 23_000_000'i32
    sim.robots[i].vx = 0
    sim.robots[i].vy = 0
  sim.ball.x = PitchXMax - 150_000'i32
  sim.ball.y = CentreY
  sim.ball.vx = 400_000'i32
  sim.ball.vy = 0
  doAssert goalScoredBy(sim.ball.x, sim.ball.y) < 0
  doAssert sim.goals(Azure) == 0
  sim.stepIdle()
  doAssert sim.goals(Azure) == 1, "the goal did not fire on the crossing"
  doAssert sim.ball.x == CentreX and sim.ball.y == CentreY,
    "the kickoff reset did not place the ball on the centre spot"
  doAssert sim.freezeUntil > int32(sim.tickCount) - 1,
    "the kickoff freeze was not armed"
  # And not a millimetre early: a ball just short of the plane scores nothing.
  var short = playing(testConfig())
  short.ball.x = PitchXMax - 1'i32
  short.ball.y = CentreY
  doAssert goalScoredBy(short.ball.x, short.ball.y) < 0
  doAssert goalScoredBy(PitchXMax, CentreY) == int32(ord(Azure))
  doAssert goalScoredBy(PitchXMin, CentreY) == int32(ord(Crimson))
  doAssert goalScoredBy(PitchXMax, GoalYMin - 1) < 0,
    "a ball outside the mouth band scored"
  report "the goal test fires on the exact plane crossing"

proc postBounce() =
  ## A ball rolled onto a post bounces and emits `post`.
  var sim = playing(testConfig())
  sim.collectEvents = true
  for i in 0 ..< RobotCount:
    sim.robots[i].x = CentreX + int32(i) * 400_000'i32
    sim.robots[i].y = 23_000_000'i32
  sim.ball.x = PitchXMax - 1_200_000'i32
  sim.ball.y = GoalYMin
  sim.ball.vx = 300_000'i32
  sim.ball.vy = 0
  var sawPost = false
  for _ in 0 ..< 20:
    sim.stepIdle()
    for event in sim.events:
      if event.kind == Post:
        sawPost = true
    sim.events.setLen(0)
    if sawPost:
      break
  doAssert sawPost, "the ball did not touch a post"
  doAssert sim.ball.vx <= 0 or sim.ball.vy != 0,
    "the post did not deflect the ball"
  report "a ball on the post bounces and emits `post`"

proc kickoffPlacement() =
  ## The kickoff places all seven bodies at the documented coordinates, jitter
  ## included, and is seed-pinned.
  var sim = seatedSim(testConfig())
  sim.startGame()
  doAssert sim.ball.x == CentreX and sim.ball.y == CentreY
  doAssert sim.ball.vx == 0 and sim.ball.vy == 0
  let restart = Seat(sim.restartSeat and 1)
  for i in 0 ..< RobotCount:
    let
      seat = seatOfRobot(i)
      slot = i mod RobotsPerSeat
    doAssert sim.robots[i].vx == 0 and sim.robots[i].vy == 0
    doAssert sim.robots[i].spin == 0
    doAssert sim.robots[i].kickCooldown == 0
    doAssert sim.robots[i].headingQ ==
      (if seat == Azure: 0'i32 else: 2048'i32)
    if slot == 0:
      let want =
        if seat == restart: CentreX - 1_500_000'i32 * attackDir(seat)
        else: CentreX - 3_000_000'i32 * attackDir(seat)
      doAssert sim.robots[i].x == want,
        "robot " & robotId(i) & " x " & $sim.robots[i].x & " != " & $want
      doAssert sim.robots[i].y == CentreY
    else:
      doAssert sim.robots[i].x == CentreX - 9_000_000'i32 * attackDir(seat)
      let base = CentreY + (if slot == 1: -4_500_000'i32 else: 4_500_000'i32)
      doAssert abs(sim.robots[i].y - base) <= 250_000'i32,
        "flank jitter out of range: " & $(sim.robots[i].y - base)
  # Seed-pinned: the same seed produces byte-identical placement.
  var again = seatedSim(testConfig())
  again.startGame()
  for i in 0 ..< RobotCount:
    doAssert again.robots[i].y == sim.robots[i].y,
      "the kickoff jitter is not seed-pinned"
  report "the kickoff places all seven bodies exactly, jitter seed-pinned"

proc neutralDropFires() =
  ## The drop fires at exactly `stalemateTicks` and clears the 3 m radius.
  var config = testConfig()
  var sim = playing(config)
  sim.collectEvents = true
  # Park the ball and every robot dead still in a corner.
  sim.ball.x = 3_000_000'i32
  sim.ball.y = 1_000_000'i32
  sim.ball.vx = 0
  sim.ball.vy = 0
  sim.anchorX = sim.ball.x
  sim.anchorY = sim.ball.y
  sim.stalemateTicks = 0
  for i in 0 ..< RobotCount:
    sim.robots[i].x = 3_500_000'i32 + int32(i) * 200_000'i32
    sim.robots[i].y = 1_500_000'i32
    sim.robots[i].vx = 0
    sim.robots[i].vy = 0
  for tick in 1 ..< config.stalemateTicks:
    sim.stepIdle()
    doAssert sim.stalemateTicks == int32(tick),
      "the stalemate counter did not advance: " & $sim.stalemateTicks
  sim.stepIdle()
  doAssert sim.stalemateTicks == 0, "the drop did not reset the counter"
  let spot = nearestDropSpot(3_000_000'i32, 1_000_000'i32)
  doAssert sim.ball.x == spot.x and sim.ball.y == spot.y,
    "the ball was not dropped on the nearest spot"
  for i in 0 ..< RobotCount:
    doAssert distI(sim.robots[i].x - spot.x, sim.robots[i].y - spot.y) >=
      DropClearRadius - 2,
      "robot " & robotId(i) & " is still inside the drop radius"
  report "the neutral drop fires at 240 ticks and clears the radius"

proc kickRangeMatchesArt() =
  ## The kick radius and the drawn robot are two numbers in two modules and
  ## nothing structurally ties them (AGENTS.md). Assert the relationship.
  doAssert KickRange == RobotRadius + BallRadius + KickReach
  doAssert KickReach > 0 and KickReach < RobotRadius,
    "the kick slack must be a fraction of the hull, not another hull"
  report "the kick radius is derived from the two body radii"

when isMainModule:
  echo "test_physics"
  noTunnelling()
  wallRestitution()
  robotPairSymmetry()
  kickModel()
  kickArc()
  goalPlane()
  postBounce()
  kickoffPlacement()
  neutralDropFires()
  kickRangeMatchesArt()
  echo "test_physics: all good"
