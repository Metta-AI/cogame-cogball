## The control layer: a pure, integer-only function of
## (sim state, directive, robot index) -> one Sprite v1 input mask.
##
## Both LLM directives and scripted directives are compiled by THIS code, so
## the two policy kinds are strictly comparable. The layer sits OUTSIDE the
## determinism boundary — the viewer never runs it, it replays the recorded
## masks — which is why the whole class of "the control layer was
## reimplemented in the viewer and drifted" bugs is structurally impossible.
##
## No floating point: `tests/test_determinism.nim` greps this file.

import
  bitworld/spriteprotocol,
  sim

const
  StandOff = 900_000'i32     ## how far behind the ball a striking robot lines up.
  ArriveUm = 300_000'i32     ## "close enough" for thrust to cut out.
  HoldUm = 400_000'i32       ## a holding robot inside this faces the ball.
  BackOutUm = 2_000_000'i32  ## reverse instead of pirouetting inside this.
  BrakeSpeed = 40_000'i32    ## along-heading speed that arms the brake.
  ThrustErr = 48'i32         ## brads of aim error thrust tolerates.
  ReverseErr = 96'i32        ## brads past which the robot backs out.
  TurnDeadband = 8'i32       ## PD deadband, in the PD term's own units.
  KickAimErr = 32'i32        ## brads of aim error a kick tolerates.
  InterceptMaxTicks = 36'i32
  PressLeadTicks = 12'i32
  PassLeadTicks = 12'i32
  BoardsInsetLo = 3_000_000'i32
  BoardsInsetHi = 22_000_000'i32
  EscapeDepth = 6_000_000'i32

proc offsetTowards(
  fromX, fromY, toX, toY, distance: int32
): tuple[x, y: int32] {.inline.} =
  ## The point `distance` micrometres from (fromX, fromY) on the side AWAY from
  ## (toX, toY) — where a robot stands to strike the ball at a target.
  let u = unitQ12(toX - fromX, toY - fromY)
  (fromX - int32((int64(distance) * int64(u.x)) div 4096),
   fromY - int32((int64(distance) * int64(u.y)) div 4096))

proc nearestOfTrio*(sim: SimServer, seat: Seat): int =
  ## The robot of a seat's trio closest to the ball; ties by ascending index.
  var
    best = firstRobotOf(seat)
    bestD = high(int64)
  for slot in 0 ..< RobotsPerSeat:
    let
      i = firstRobotOf(seat) + slot
      dx = int64(sim.ball.x) - int64(sim.robots[i].x)
      dy = int64(sim.ball.y) - int64(sim.robots[i].y)
      d = dx * dx + dy * dy
    if d < bestD:
      bestD = d
      best = i
  best

proc nearestOpponentToBall*(sim: SimServer, seat: Seat): int =
  var
    best = firstRobotOf(other(seat))
    bestD = high(int64)
  for slot in 0 ..< RobotsPerSeat:
    let
      i = firstRobotOf(other(seat)) + slot
      dx = int64(sim.ball.x) - int64(sim.robots[i].x)
      dy = int64(sim.ball.y) - int64(sim.robots[i].y)
      d = dx * dx + dy * dy
    if d < bestD:
      bestD = d
      best = i
  best

proc bradError(want, have: int32): int32 {.inline.} =
  ## The signed smallest brad difference, in [-128, 127].
  (((want - have + 128) mod 256 + 256) mod 256) - 128

proc compileMask*(
  sim: SimServer,
  index: int,
  directive: Directive
): uint8 =
  ## One robot's actuator mask for one tick.
  let
    seat = seatOfRobot(index)
    slot = index - firstRobotOf(seat)
    order = directive.robots[slot]
    robot = sim.robots[index]
    ball = sim.ball
    goalX = targetGoalX(seat)

  # ---- 1. the steering point ------------------------------------------------
  var
    px = ball.x
    py = ball.y
    aimX = goalX
    aimY = CentreY
    intent = order.intent
  var passTarget = order.passTo
  if intent == inPass:
    if passTarget < 0 or passTarget == int32(index) or
        seatOfRobot(int(passTarget)) != seat:
      intent = inShoot                 ## pass degrades to shoot.
      passTarget = -1

  case intent
  of inChase:
    px = ball.x
    py = ball.y
    aimX = goalX
    aimY = CentreY
  of inIntercept:
    let
      dist = distI(ball.x - robot.x, ball.y - robot.y)
      ballSpeed = speedOf(ball.vx, ball.vy)
      denom = max(1'i32, int32(sim.config.robotMaxSpeed) + ballSpeed)
      tau = clamp(dist div denom, 0'i32, InterceptMaxTicks)
    px = ball.x + int32(int64(ball.vx) * int64(tau))
    py = ball.y + int32(int64(ball.vy) * int64(tau))
    aimX = goalX
    aimY = CentreY
  of inHold:
    px = order.targetX
    py = order.targetY
    aimX = ball.x
    aimY = ball.y
  of inShoot:
    let stand = offsetTowards(ball.x, ball.y, goalX, CentreY, StandOff)
    px = stand.x
    py = stand.y
    aimX = goalX
    aimY = CentreY
  of inPass:
    let
      mate = sim.robots[int(passTarget)]
      tx = mate.x + int32(int64(mate.vx) * int64(PassLeadTicks))
      ty = mate.y + int32(int64(mate.vy) * int64(PassLeadTicks))
      stand = offsetTowards(ball.x, ball.y, tx, ty, StandOff)
    px = stand.x
    py = stand.y
    aimX = tx
    aimY = ty
  of inClear:
    let
      cx = CentreX
      cy = if ball.y < CentreY: 2_500_000'i32 else: 22_500_000'i32
      stand = offsetTowards(ball.x, ball.y, cx, cy, StandOff)
    px = stand.x
    py = stand.y
    aimX = cx
    aimY = cy
  of inPress:
    let opponent = sim.robots[sim.nearestOpponentToBall(seat)]
    px = opponent.x + int32(int64(opponent.vx) * int64(PressLeadTicks))
    py = opponent.y + int32(int64(opponent.vy) * int64(PressLeadTicks))
    aimX = ball.x
    aimY = ball.y

  if intent != inHold:
    # Every intent except hold blends the directive target as a 20% bias.
    px = int32((int64(px) * 4 + int64(order.targetX)) div 5)
    py = int32((int64(py) * 4 + int64(order.targetY)) div 5)

  # ---- 2. the boards-escape override ---------------------------------------
  var boardsOverride = false
  if onBoards(ball.x, ball.y):
    if index == sim.nearestOfTrio(seat):
      let
        ex = CentreX + EscapeDepth * attackDir(seat)
        ey = CentreY
        stand = offsetTowards(ball.x, ball.y, ex, ey, StandOff)
      px = stand.x
      py = stand.y
      aimX = ex
      aimY = ey
      boardsOverride = true
    else:
      # Robots that are not the closest of their trio are pushed off the
      # boards, so a whole trio cannot pile into one corner.
      py = clamp(py, BoardsInsetLo, BoardsInsetHi)

  # ---- 3. the turn command --------------------------------------------------
  var dx = px - robot.x
  var dy = py - robot.y
  let dist = distI(dx, dy)
  if intent == inHold and not boardsOverride and dist < HoldUm:
    # A holding robot that has arrived faces the ball. Only the TURN target
    # moves: `dist` still measures the distance to the held spot, so the robot
    # holds the point instead of driving off at the ball.
    dx = ball.x - robot.x
    dy = ball.y - robot.y
  let
    want = bradsOfVectorI(dx, dy)
    err = bradError(want, robot.headingBrads())
    pd = err * 16 - 2 * robot.spin
  var mask = 0'u8
  if pd > TurnDeadband:
    mask = mask or ButtonLeft
  elif pd < -TurnDeadband:
    mask = mask or ButtonRight

  # ---- 4. thrust and brake --------------------------------------------------
  let absErr = abs(err)
  var braking = false
  if absErr <= ThrustErr and dist > ArriveUm:
    mask = mask or ButtonUp
  elif absErr > ReverseErr and dist < BackOutUm:
    mask = mask or ButtonDown
  if dist < ArriveUm:
    let h = robot.headingVec()
    let along = int32((int64(robot.vx) * int64(h.x) +
      int64(robot.vy) * int64(h.y)) div 4096)
    if abs(along) > BrakeSpeed:
      mask = mask or ButtonSelect
      braking = true
  discard braking

  # ---- 5. the kick ----------------------------------------------------------
  var wantKick = order.kick == kickAuto or boardsOverride
  if intent in {inHold, inPress} and not boardsOverride:
    # A holding or pressing robot only kicks the ball off its own goal line.
    let
      ownX = ownGoalX(seat)
      betweenX = abs(int64(ball.x) - int64(ownX)) <
        abs(int64(robot.x) - int64(ownX))
    if not betweenX:
      wantKick = false
    aimX = CentreX
    aimY = CentreY
  if wantKick and robot.kickCooldown == 0:
    let ballDist = distI(ball.x - robot.x, ball.y - robot.y)
    if ballDist <= KickRange:
      if intent in {inChase, inIntercept} and not boardsOverride:
        # No declared kick target: drive the ball away from your own goal.
        aimX = targetGoalX(seat)
        aimY = CentreY
      let
        aimWant = bradsOfVectorI(aimX - robot.x, aimY - robot.y)
        aimErr = abs(bradError(aimWant, robot.headingBrads()))
      if aimErr <= KickAimErr:
        mask = mask or ButtonA
  mask

proc compileMasks*(
  sim: SimServer,
  directives: array[Seat, Directive]
): array[RobotCount, uint8] =
  ## The six masks for one tick, in robot index order. Every robot always has
  ## a directive, so no failure mode can leave one unactuated. During the
  ## kickoff freeze every mask is zero.
  if sim.phase != Playing or int32(sim.tickCount) < sim.freezeUntil:
    return
  for i in 0 ..< RobotCount:
    result[i] = sim.compileMask(i, directives[seatOfRobot(i)])
