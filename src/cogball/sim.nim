## The deterministic gameplay core: the integer physics, the kick model, the
## kickoff and neutral-drop restarts, the shot/save/pass bookkeeping and the
## per-tick step loop. Types, consts, pitch geometry, config and state services
## live in the sibling modules this file imports and re-exports, exactly as
## ctf's `sim.nim` does.
##
## THE DETERMINISM CONTRACT (docs/RULES.md §Determinism):
##
## * every stored field is an explicit `int32` / `bool` / enum — never a bare
##   `int`, which is 64-bit natively and 32-bit under `--cpu:wasm32`;
## * every product or quotient of two sim quantities is taken in `int64` and
##   narrowed with an explicit truncating `div` (Nim's `div` truncates toward
##   zero, so the arithmetic is symmetric under negation — which is what makes
##   the two ends of the pitch exactly fair);
## * there is no floating point in this module, and no libm call anywhere: the
##   only trigonometry is the committed `SinQ12` table in `trig.nim`, the only
##   square root is `isqrt`, and the only atan2 is `bradsOfVectorI`.
##
## The recorded action log is the six robots' Sprite v1 input masks. The
## control layer, the LLM and the directive records are all OUTSIDE this
## boundary: the wasm viewer never runs them, it feeds the recorded masks to
## this identical core.

import
  std/random,
  bitworld/spriteprotocol

import sim_types, trig, pitch, sim_config, sim_state
export sim_types, trig, pitch, sim_config, sim_state

# --------------------------------------------------------------------------
# Small integer helpers. Every one of these takes its product in int64.
# --------------------------------------------------------------------------

proc q12Scale*(value, unit: int32): int32 {.inline.} =
  ## value * unit / 4096, where `unit` is a Q12 direction component.
  int32((int64(value) * int64(unit)) div 4096)

proc pctScale*(value: int32, pct: int32): int32 {.inline.} =
  int32((int64(value) * int64(pct)) div 100)

proc permilScale(value: int32, num: int32): int32 {.inline.} =
  ## value * num / 1024 — the drag/grip unit.
  int32((int64(value) * int64(num)) div 1024)

proc headingBrads*(robot: Robot): int32 {.inline.} =
  (robot.headingQ div 16) and 255

proc headingVec*(robot: Robot): tuple[x, y: int32] {.inline.} =
  ## The Q12 unit vector a robot faces. 0 = east, counter-clockwise on screen.
  let b = robot.headingBrads()
  (cosQ12(b), -sinQ12(b))

proc speedOf*(vx, vy: int32): int32 {.inline.} =
  distI(vx, vy)

proc capSpeed(vx, vy: var int32, cap: int32) {.inline.} =
  let s = speedOf(vx, vy)
  if s > cap and s > 0:
    vx = int32((int64(vx) * int64(cap)) div int64(s))
    vy = int32((int64(vy) * int64(cap)) div int64(s))

proc unitQ12*(dx, dy: int32): tuple[x, y, d: int32] {.inline.} =
  ## A Q12 unit vector plus the length it was derived from. A zero vector
  ## resolves to east, so nothing in the sim can divide by zero.
  let d = distI(dx, dy)
  if d <= 0:
    return (4096'i32, 0'i32, 0'i32)
  (int32((int64(dx) * 4096) div int64(d)),
   int32((int64(dy) * 4096) div int64(d)), d)

# --------------------------------------------------------------------------
# Construction
# --------------------------------------------------------------------------

proc kickoffReset*(sim: var SimServer, restartSeat: int32)

proc initSimServer*(config: GameConfig): SimServer =
  ## Builds a fresh sim from a resolved config. No sockets, no rendering.
  result.config = config
  result.rng = initRand(config.seed)
  result.phase = Lobby
  result.winner = Azure
  result.endReason = reasonComplete
  result.endRule = erFullTime
  result.gameStartTick = -1
  result.lastLobbyPlayersLogged = -1
  result.lastLobbyNeededLogged = -1
  result.lastLobbySecondsLogged = -1
  result.lastTouch = Touch(robot: -1, seat: -1, tick: -1)
  result.prevTouch = Touch(robot: -1, seat: -1, tick: -1)
  result.lastGoalTick = -1
  result.lastGoalSeat = -1
  result.lastGoalBy = -1
  result.lastGoalAssist = -1
  result.lastDropTick = -1
  result.pendingShot = ShotRecord(seat: -1, robot: -1, tick: -1)
  result.pendingPass = PassRecord(seat: -1, robot: -1, tick: -1, target: -1)
  result.gameEventLoggingEnabled = true
  for i in 0 ..< RobotCount:
    result.robots[i].seat = int32(ord(seatOfRobot(i)))
  # Every robot has a directive from tick zero, so no failure mode — not even
  # a turn that never ran — can leave one unactuated.
  for seat in Seat:
    for slot in 0 ..< RobotsPerSeat:
      result.activeDirective[seat].robots[slot] = RobotOrder(
        role: roleWing, intent: inChase,
        targetX: CentreX, targetY: CentreY,
        passTo: -1, kick: kickAuto, say: "")
  result.kickoffReset(int32(config.seed and 1))
  # The construction-time placement is not a kickoff -- the match has not
  # started -- so the beat field it just set is cleared again. `startGame`'s
  # own kickoffReset is the first real one.
  result.lastKickoffTick = -1
  result.freezeUntil = 0

proc effectiveMaxTicks*(sim: SimServer): int {.inline.} =
  sim.config.maxTicks

proc turnTicks*(sim: SimServer): int {.inline.} =
  max(1, sim.config.turnTicks)

proc turnCount*(sim: SimServer): int {.inline.} =
  max(1, sim.config.maxTicks div sim.turnTicks())

proc gameTicksElapsed*(sim: SimServer): int {.inline.} =
  if sim.gameStartTick < 0: 0 else: max(0, sim.tickCount - sim.gameStartTick)

proc currentTurn*(sim: SimServer): int {.inline.} =
  sim.gameTicksElapsed() div sim.turnTicks()

proc goals*(sim: SimServer, seat: Seat): int {.inline.} =
  int(sim.stats[seat].goals)

proc goalDiff*(sim: SimServer, seat: Seat): int {.inline.} =
  sim.goals(seat) - sim.goals(other(seat))

# --------------------------------------------------------------------------
# Restarts
# --------------------------------------------------------------------------

proc placeRobot(sim: var SimServer, index: int, x, y: int32) =
  sim.robots[index].x = x
  sim.robots[index].y = y
  sim.robots[index].vx = 0
  sim.robots[index].vy = 0
  sim.robots[index].spin = 0
  sim.robots[index].kickCooldown = 0

proc kickoffReset*(sim: var SimServer, restartSeat: int32) =
  ## The exact kickoff placement (docs/RULES.md §Kickoff). The restarting seat
  ## is the conceding one; at match start it is `config.seed and 1`.
  ##
  ## This runs TWICE before a match's first played tick: once from
  ## `initSimServer` (the bodies have to be somewhere while the lobby fills)
  ## and once from `startGame`. So the placement a match kicks off from is the
  ## SECOND set of jitter draws. Determinism is unaffected -- the viewer
  ## reconstructs with `initSimServer(config)` and re-steps from tick 0, so
  ## both draws happen in the same order on both sides of the native/wasm
  ## boundary -- and tests/test_physics.nim pins the resulting coordinates
  ## against the seed. See docs/plans/note-divergences.md.
  sim.restartSeat = restartSeat
  sim.ball = Ball(x: CentreX, y: CentreY, vx: 0, vy: 0)
  sim.stalemateTicks = 0
  sim.anchorX = CentreX
  sim.anchorY = CentreY
  sim.lastTouch = Touch(robot: -1, seat: -1, tick: -1)
  sim.prevTouch = Touch(robot: -1, seat: -1, tick: -1)
  sim.pendingShot = ShotRecord(seat: -1, robot: -1, tick: -1)
  sim.pendingPass = PassRecord(seat: -1, robot: -1, tick: -1, target: -1)
  let
    restart = Seat(restartSeat and 1)
    away = other(restart)
  for i in 0 ..< RobotCount:
    let seat = seatOfRobot(i)
    sim.robots[i].headingQ = if seat == Azure: 0'i32 else: 2048'i32
    let slot = i mod RobotsPerSeat
    if slot == 0:
      if seat == restart:
        sim.placeRobot(i, CentreX - 1_500_000'i32 * attackDir(seat), CentreY)
      else:
        sim.placeRobot(i, CentreX - 3_000_000'i32 * attackDir(seat), CentreY)
    else:
      # The four flank robots take a deterministic y jitter from the seeded sim
      # RNG — the same stream ctf uses for respawn placement, integer draws only.
      let jitter = int32(sim.rng.rand(500_000) - 250_000)
      let dy = if slot == 1: -4_500_000'i32 else: 4_500_000'i32
      sim.placeRobot(i,
        CentreX - 9_000_000'i32 * attackDir(seat),
        CentreY + dy + jitter)
  discard away
  sim.lastKickoffTick = int32(sim.tickCount)
  sim.emitEvent(Kickoff, seat = int(restartSeat), x = CentreX, y = CentreY)

proc neutralDrop(sim: var SimServer) =
  ## The corner-stalemate cure, INSIDE the sim so no policy can defeat it.
  let spot = nearestDropSpot(sim.ball.x, sim.ball.y)
  sim.ball = Ball(x: spot.x, y: spot.y, vx: 0, vy: 0)
  for i in 0 ..< RobotCount:
    let
      dx = sim.robots[i].x - spot.x
      dy = sim.robots[i].y - spot.y
      u = unitQ12(dx, dy)
    if u.d < DropClearRadius:
      sim.robots[i].x = spot.x + q12Scale(DropClearRadius, u.x)
      sim.robots[i].y = spot.y + q12Scale(DropClearRadius, u.y)
      sim.robots[i].vx = 0
      sim.robots[i].vy = 0
      sim.robots[i].spin = 0
  sim.stalemateTicks = 0
  sim.anchorX = spot.x
  sim.anchorY = spot.y
  sim.lastTouch = Touch(robot: -1, seat: -1, tick: -1)
  sim.prevTouch = Touch(robot: -1, seat: -1, tick: -1)
  sim.pendingShot = ShotRecord(seat: -1, robot: -1, tick: -1)
  sim.pendingPass = PassRecord(seat: -1, robot: -1, tick: -1, target: -1)
  sim.lastDropTick = int32(sim.tickCount)
  sim.emitEvent(Drop, x = spot.x, y = spot.y)
  sim.logGameEvent("neutral drop at " & $spot.x & "," & $spot.y)

# --------------------------------------------------------------------------
# Endings
# --------------------------------------------------------------------------

proc finishGame*(sim: var SimServer, reason: EndReason, rule: EndRule) =
  ## Ends the match. Idempotent: the first ending wins, so a wall-clock stop
  ## landing on the same tick as full time cannot overwrite the verdict.
  if sim.phase == GameOver:
    return
  sim.endReason = reason
  sim.endRule = rule
  sim.ended = true
  let diff = sim.goalDiff(Azure)
  if reason == reasonFault or diff == 0:
    sim.isDraw = true
    sim.winner = Azure
  else:
    sim.isDraw = false
    sim.winner = if diff > 0: Azure else: Crimson
  sim.emitPhaseChange(GameOver)
  sim.phase = GameOver
  sim.gameOverTimer = sim.config.gameOverTicks
  sim.logGameEvent("game over: " & reasonText(reason) & "/" &
    endRuleText(rule) & " " & $sim.goals(Azure) & "-" & $sim.goals(Crimson))

proc startGame*(sim: var SimServer) =
  sim.emitPhaseChange(Playing)
  sim.phase = Playing
  sim.gameStartTick = sim.tickCount
  sim.kickoffReset(int32(sim.config.seed and 1))
  sim.freezeUntil = int32(sim.tickCount) + KickoffFreezeTicks
  sim.logGameEvent("match start, kickoff for seat " & $sim.restartSeat)

# --------------------------------------------------------------------------
# Kicks
# --------------------------------------------------------------------------

proc registerShot(sim: var SimServer, robot: int) =
  ## Classifies the ball's post-kick velocity ray against the opponent goal.
  let
    seat = seatOfRobot(robot)
    goalX = targetGoalX(seat)
    dx = int64(goalX) - int64(sim.ball.x)
    vx = int64(sim.ball.vx)
  if vx == 0 or (dx > 0) != (vx > 0):
    return
  let crossY = int64(sim.ball.y) + (int64(sim.ball.vy) * dx) div vx
  let inMouth = crossY >= int64(GoalYMin) and crossY <= int64(GoalYMax)
  let near =
    crossY >= int64(GoalYMin) - 4_500_000'i64 and
    crossY <= int64(GoalYMax) + 4_500_000'i64
  if not near:
    return
  inc sim.stats[seat].shots
  if inMouth:
    inc sim.stats[seat].shotsOnTarget
    sim.pendingShot = ShotRecord(
      seat: int32(ord(seat)), robot: int32(robot),
      tick: int32(sim.tickCount), onTarget: true)
  sim.emitEvent(Shot, source = robot, seat = ord(seat),
    amount = ord(inMouth), x = sim.ball.x, y = sim.ball.y,
    speed = speedOf(sim.ball.vx, sim.ball.vy))

proc applyKicks(sim: var SimServer, inputs: openArray[InputState]) =
  ## Step 5 of the resolution order. In robot index order, so each kick sees
  ## the ball state the previous kick in the same tick left behind.
  for i in 0 ..< RobotCount:
    if i >= inputs.len or not inputs[i].attack:
      continue
    if sim.robots[i].kickCooldown != 0:
      continue
    let
      dx = sim.ball.x - sim.robots[i].x
      dy = sim.ball.y - sim.robots[i].y
      d = distI(dx, dy)
    if d > KickRange:
      continue
    let h = sim.robots[i].headingVec()
    # +-60 degree frontal arc, as an exact integer test: cos(angle) >= 1/2.
    let dot = int64(dx) * int64(h.x) + int64(dy) * int64(h.y)
    if 2'i64 * dot < int64(d) * 4096'i64:
      continue
    let
      vpar = int32((int64(sim.ball.vx) * int64(h.x) +
        int64(sim.ball.vy) * int64(h.y)) div 4096)
      vperpX = sim.ball.vx - q12Scale(vpar, h.x)
      vperpY = sim.ball.vy - q12Scale(vpar, h.y)
      impulse = int32(sim.config.kickImpulse)
      vparNew = max(vpar, 0'i32) + impulse
    sim.ball.vx = vperpX div 2 + q12Scale(vparNew, h.x)
    sim.ball.vy = vperpY div 2 + q12Scale(vparNew, h.y)
    capSpeed(sim.ball.vx, sim.ball.vy, int32(sim.config.ballMaxSpeed))
    # Reaction: the ball's momentum change divided by the robot's mass.
    let react = int32((int64(BallMassG) * int64(vparNew - vpar)) div
      int64(RobotMassG))
    sim.robots[i].vx -= q12Scale(react, h.x)
    sim.robots[i].vy -= q12Scale(react, h.y)
    sim.robots[i].kickCooldown = KickCooldownTicks
    let seat = seatOfRobot(i)
    inc sim.stats[seat].kicks
    # A kick is a touch: it re-opens the pass window and re-anchors the
    # possession chain.
    if sim.lastTouch.robot != int32(i):
      sim.prevTouch = sim.lastTouch
    sim.lastTouch = Touch(robot: int32(i), seat: int32(ord(seat)),
      tick: int32(sim.tickCount))
    sim.pendingPass = PassRecord(seat: int32(ord(seat)), robot: int32(i),
      tick: int32(sim.tickCount), target: -1)
    sim.kickFx.add KickFx(x: sim.ball.x, y: sim.ball.y,
      tick: int32(sim.tickCount), seat: int32(ord(seat)))
    sim.emitEvent(Kick, source = i, seat = ord(seat),
      x = sim.ball.x, y = sim.ball.y,
      speed = speedOf(sim.ball.vx, sim.ball.vy))
    sim.registerShot(i)

# --------------------------------------------------------------------------
# Substeps
# --------------------------------------------------------------------------

proc integrateRobots(sim: var SimServer, inputs: openArray[InputState]) =
  for i in 0 ..< RobotCount:
    var input: InputState
    if i < inputs.len:
      input = inputs[i]
    var uTurn = 0'i32
    if input.left: uTurn += 1
    if input.right: uTurn -= 1
    var uThrust = 0'i32
    if input.up: uThrust += 1
    if input.down: uThrust -= 1
    if input.select:
      uThrust = 0
    var r = sim.robots[i]
    r.spin = clamp(r.spin + SpinAccel * uTurn -
      permilScale(r.spin, SpinDampNum), -SpinMax, SpinMax)
    r.headingQ = (r.headingQ + r.spin div 4 + HeadingQTurn) mod HeadingQTurn
    let h = r.headingVec()
    if uThrust != 0:
      r.vx += q12Scale(ThrustAccel * uThrust, h.x)
      r.vy += q12Scale(ThrustAccel * uThrust, h.y)
    # Lateral grip: scrub off the component across the heading.
    let along = int32((int64(r.vx) * int64(h.x) +
      int64(r.vy) * int64(h.y)) div 4096)
    let
      latX = r.vx - q12Scale(along, h.x)
      latY = r.vy - q12Scale(along, h.y)
      grip = if input.select: GripBrakeNum else: GripNum
    r.vx -= permilScale(latX, grip)
    r.vy -= permilScale(latY, grip)
    r.vx -= permilScale(r.vx, RobotDragNum)
    r.vy -= permilScale(r.vy, RobotDragNum)
    capSpeed(r.vx, r.vy, int32(sim.config.robotMaxSpeed))
    let
      stepX = r.vx div Substeps
      stepY = r.vy div Substeps
    r.x += stepX
    r.y += stepY
    r.distanceUm += int64(distI(stepX, stepY))
    sim.robots[i] = r

proc integrateBall(sim: var SimServer) =
  sim.ball.vx -= permilScale(sim.ball.vx, BallDragNum)
  sim.ball.vy -= permilScale(sim.ball.vy, BallDragNum)
  capSpeed(sim.ball.vx, sim.ball.vy, int32(sim.config.ballMaxSpeed))
  sim.ball.x += sim.ball.vx div Substeps
  sim.ball.y += sim.ball.vy div Substeps

proc resolveRobotWalls(sim: var SimServer) =
  for i in 0 ..< RobotCount:
    var r = sim.robots[i]
    let yb = yBounds(r.x, RobotRadius)
    if r.y < yb.lo:
      r.y = yb.lo
      if r.vy < 0: r.vy = -pctScale(r.vy, WallRestitutionPct)
    elif r.y > yb.hi:
      r.y = yb.hi
      if r.vy > 0: r.vy = -pctScale(r.vy, WallRestitutionPct)
    let xb = xBounds(r.y, RobotRadius)
    if r.x < xb.lo:
      r.x = xb.lo
      if r.vx < 0: r.vx = -pctScale(r.vx, WallRestitutionPct)
    elif r.x > xb.hi:
      r.x = xb.hi
      if r.vx > 0: r.vx = -pctScale(r.vx, WallRestitutionPct)
    sim.robots[i] = r

proc resolveRobotPairs(sim: var SimServer) =
  const Span = RobotRadius + RobotRadius
  for a in 0 ..< RobotCount - 1:
    for b in a + 1 ..< RobotCount:
      let
        dx = sim.robots[b].x - sim.robots[a].x
        dy = sim.robots[b].y - sim.robots[a].y
        u = unitQ12(dx, dy)
      if u.d >= Span:
        continue
      let
        pen = Span - u.d
        half = pen div 2
        sx = q12Scale(half, u.x)
        sy = q12Scale(half, u.y)
      sim.robots[a].x -= sx
      sim.robots[a].y -= sy
      sim.robots[b].x += sx
      sim.robots[b].y += sy
      let rel = int32((int64(sim.robots[b].vx - sim.robots[a].vx) *
        int64(u.x) + int64(sim.robots[b].vy - sim.robots[a].vy) *
        int64(u.y)) div 4096)
      if rel >= 0:
        continue
      # Equal masses: each body takes half of (1 + e) * (-rel).
      let j = pctScale(-rel, 100 + RobotRestitutionPct) div 2
      let
        jx = q12Scale(j, u.x)
        jy = q12Scale(j, u.y)
      sim.robots[a].vx -= jx
      sim.robots[a].vy -= jy
      sim.robots[b].vx += jx
      sim.robots[b].vy += jy

proc recordTouch(sim: var SimServer, robot: int) =
  let seat = seatOfRobot(robot)
  if sim.lastTouch.robot == int32(robot):
    sim.lastTouch.tick = int32(sim.tickCount)
    return
  # A completed pass / interception is derived from state alone: the kicker,
  # then the next DIFFERENT robot to touch the ball inside the window. Intent
  # lives outside the determinism boundary, so it cannot be read here.
  if sim.pendingPass.robot >= 0 and sim.pendingPass.robot != int32(robot) and
      int32(sim.tickCount) - sim.pendingPass.tick <= PassWindowTicks:
    if sim.pendingPass.seat == int32(ord(seat)):
      inc sim.stats[seat].passesCompleted
      sim.emitEvent(Pass, source = int(sim.pendingPass.robot), target = robot,
        seat = ord(seat))
    else:
      inc sim.stats[seat].interceptions
      sim.emitEvent(Interception, source = int(sim.pendingPass.robot),
        target = robot, seat = ord(seat))
    sim.pendingPass = PassRecord(seat: -1, robot: -1, tick: -1, target: -1)
  # A save: the next touch after a shot on target, by a defender inside its
  # own penalty area, before any goal.
  if sim.pendingShot.robot >= 0 and sim.pendingShot.seat != int32(ord(seat)):
    if inOwnPenaltyArea(seat, sim.robots[robot].x, sim.robots[robot].y):
      inc sim.stats[seat].saves
      sim.emitEvent(Save, source = robot, seat = ord(seat))
    sim.pendingShot = ShotRecord(seat: -1, robot: -1, tick: -1)
  elif sim.pendingShot.robot >= 0:
    sim.pendingShot = ShotRecord(seat: -1, robot: -1, tick: -1)
  sim.prevTouch = sim.lastTouch
  sim.lastTouch = Touch(robot: int32(robot), seat: int32(ord(seat)),
    tick: int32(sim.tickCount))
  sim.emitEvent(TouchEvent, source = robot, seat = ord(seat),
    x = sim.ball.x, y = sim.ball.y)

proc resolveBallRobots(sim: var SimServer) =
  const Span = RobotRadius + BallRadius
  const TotalMass = RobotMassG + BallMassG
  for i in 0 ..< RobotCount:
    let
      dx = sim.ball.x - sim.robots[i].x
      dy = sim.ball.y - sim.robots[i].y
      u = unitQ12(dx, dy)
    if u.d >= Span:
      continue
    let
      pen = Span - u.d
      ballShift = int32((int64(pen) * int64(RobotMassG)) div int64(TotalMass))
      robotShift = pen - ballShift
    sim.ball.x += q12Scale(ballShift, u.x)
    sim.ball.y += q12Scale(ballShift, u.y)
    sim.robots[i].x -= q12Scale(robotShift, u.x)
    sim.robots[i].y -= q12Scale(robotShift, u.y)
    let vn = int32((int64(sim.ball.vx - sim.robots[i].vx) * int64(u.x) +
      int64(sim.ball.vy - sim.robots[i].vy) * int64(u.y)) div 4096)
    if vn < 0:
      let k = pctScale(-vn, 100 + BallRobotRestitutionPct)
      let
        dvBall = int32((int64(k) * int64(RobotMassG)) div int64(TotalMass))
        dvRobot = int32((int64(k) * int64(BallMassG)) div int64(TotalMass))
      sim.ball.vx += q12Scale(dvBall, u.x)
      sim.ball.vy += q12Scale(dvBall, u.y)
      sim.robots[i].vx -= q12Scale(dvRobot, u.x)
      sim.robots[i].vy -= q12Scale(dvRobot, u.y)
    # Dribble friction: shave the tangential relative velocity.
    let
      rvx = sim.ball.vx - sim.robots[i].vx
      rvy = sim.ball.vy - sim.robots[i].vy
      vn2 = int32((int64(rvx) * int64(u.x) + int64(rvy) * int64(u.y)) div 4096)
      tx = rvx - q12Scale(vn2, u.x)
      ty = rvy - q12Scale(vn2, u.y)
    sim.ball.vx -= pctScale(tx, 100 - DribbleTangentPct)
    sim.ball.vy -= pctScale(ty, 100 - DribbleTangentPct)
    capSpeed(sim.ball.vx, sim.ball.vy, int32(sim.config.ballMaxSpeed))
    sim.recordTouch(i)

proc resolveBallPosts(sim: var SimServer) =
  const Span = PostRadius + BallRadius
  for post in Posts:
    let
      dx = sim.ball.x - post.x
      dy = sim.ball.y - post.y
      u = unitQ12(dx, dy)
    if u.d >= Span:
      continue
    sim.ball.x = post.x + q12Scale(Span, u.x)
    sim.ball.y = post.y + q12Scale(Span, u.y)
    let vn = int32((int64(sim.ball.vx) * int64(u.x) +
      int64(sim.ball.vy) * int64(u.y)) div 4096)
    if vn < 0:
      let k = pctScale(-vn, 100 + PostRestitutionPct)
      sim.ball.vx += q12Scale(k, u.x)
      sim.ball.vy += q12Scale(k, u.y)
    sim.emitEvent(Post, x = sim.ball.x, y = sim.ball.y)

proc resolveBallWalls(sim: var SimServer) =
  let yb = yBounds(sim.ball.x, BallRadius)
  if sim.ball.y < yb.lo:
    sim.ball.y = yb.lo
    if sim.ball.vy < 0:
      sim.ball.vy = -pctScale(sim.ball.vy, BallWallRestitutionPct)
      sim.ball.vx = pctScale(sim.ball.vx, BallWallTangentPct)
  elif sim.ball.y > yb.hi:
    sim.ball.y = yb.hi
    if sim.ball.vy > 0:
      sim.ball.vy = -pctScale(sim.ball.vy, BallWallRestitutionPct)
      sim.ball.vx = pctScale(sim.ball.vx, BallWallTangentPct)
  let xb = xBounds(sim.ball.y, BallRadius)
  if sim.ball.x < xb.lo:
    sim.ball.x = xb.lo
    if sim.ball.vx < 0:
      sim.ball.vx = -pctScale(sim.ball.vx, BallWallRestitutionPct)
      sim.ball.vy = pctScale(sim.ball.vy, BallWallTangentPct)
  elif sim.ball.x > xb.hi:
    sim.ball.x = xb.hi
    if sim.ball.vx > 0:
      sim.ball.vx = -pctScale(sim.ball.vx, BallWallRestitutionPct)
      sim.ball.vy = pctScale(sim.ball.vy, BallWallTangentPct)

proc scoreGoal(sim: var SimServer, scorer: Seat) =
  inc sim.stats[scorer].goals
  let
    speed = speedOf(sim.ball.vx, sim.ball.vy)
    by = int(sim.lastTouch.robot)
  var assist = -1
  if sim.prevTouch.robot >= 0 and
      sim.prevTouch.seat == int32(ord(scorer)) and
      sim.prevTouch.robot != sim.lastTouch.robot and
      int32(sim.tickCount) - sim.prevTouch.tick <= AssistWindowTicks:
    assist = int(sim.prevTouch.robot)
  sim.goalFx.add GoalFx(tick: int32(sim.tickCount), seat: int32(ord(scorer)))
  sim.lastGoalTick = int32(sim.tickCount)
  sim.lastGoalSeat = int32(ord(scorer))
  sim.lastGoalBy = int32(by)
  sim.lastGoalAssist = int32(assist)
  sim.lastGoalSpeed = speed
  sim.emitEvent(Goal, source = by, target = assist, seat = ord(scorer),
    amount = sim.goals(scorer), x = sim.ball.x, y = sim.ball.y, speed = speed)
  sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "goal",
    seat: int32(ord(scorer)),
    text: "GOAL " & seatAlias(scorer) & " - " &
      (if by >= 0: robotId(by) else: "own goal") &
      (if assist >= 0: " (assist " & robotId(assist) & ")" else: ""))
  sim.logGameEvent("goal for " & seatText(scorer) & ": " &
    $sim.goals(Azure) & "-" & $sim.goals(Crimson))
  sim.kickoffReset(int32(ord(other(scorer))))
  sim.freezeUntil = int32(sim.tickCount) + KickoffFreezeTicks

proc physicsGuardTripped(sim: SimServer): bool =
  ## The `sim_fault` guard: any body outside the arena, or moving faster than
  ## twice its cap, means the fixed-point state has gone wrong.
  if not inPitch(sim.ball.x, sim.ball.y):
    return true
  if speedOf(sim.ball.vx, sim.ball.vy) > 2 * int32(sim.config.ballMaxSpeed):
    return true
  for r in sim.robots:
    if not inPitch(r.x, r.y):
      return true
    if speedOf(r.vx, r.vy) > 2 * int32(sim.config.robotMaxSpeed):
      return true
  false

proc runSubsteps(sim: var SimServer, inputs: openArray[InputState]): bool =
  ## Four substeps of 1/96 s. Returns true when a goal abandoned the tick.
  for _ in 0 ..< Substeps:
    sim.integrateRobots(inputs)
    sim.integrateBall()
    sim.resolveRobotWalls()
    sim.resolveRobotPairs()
    sim.resolveBallRobots()
    sim.resolveBallPosts()
    sim.resolveBallWalls()
    let scorer = goalScoredBy(sim.ball.x, sim.ball.y)
    if scorer >= 0:
      sim.scoreGoal(Seat(scorer))
      return true
  false

# --------------------------------------------------------------------------
# The step loop
# --------------------------------------------------------------------------

const ZeroInputs: array[RobotCount, InputState] = default(array[RobotCount, InputState])

proc trimFx(sim: var SimServer) =
  ## Cosmetic pools are bounded so a long match cannot grow the wire without
  ## limit. None of this is in gameHash.
  const TrailLen = 45
  while sim.trail.len > TrailLen:
    sim.trail.delete(0)
  while sim.kickFx.len > 24:
    sim.kickFx.delete(0)
  while sim.goalFx.len > 8:
    sim.goalFx.delete(0)
  while sim.paint.len > 6000:
    sim.paint.delete(0)
  while sim.feed.len > 64:
    sim.feed.delete(0)

proc stepPlaying(sim: var SimServer, inputs: openArray[InputState]) =
  let frozen = int32(sim.tickCount) < sim.freezeUntil
  if frozen:
    # Kickoff freeze: masks are forced to zero and physics is skipped, but the
    # tick still advances, the hash is still written, and the turn boundary
    # still fires. EVERY velocity in the world goes to zero, the ball's
    # included -- a ball that drifts while nobody may move is not a frozen
    # restart. The kickoff reset that precedes every freeze already parks the
    # ball, so this holds the invariant rather than creating it.
    for i in 0 ..< RobotCount:
      sim.robots[i].vx = 0
      sim.robots[i].vy = 0
      sim.robots[i].spin = 0
    sim.ball.vx = 0
    sim.ball.vy = 0
  else:
    sim.applyKicks(inputs)
    discard sim.runSubsteps(inputs)

  for i in 0 ..< RobotCount:
    if sim.robots[i].kickCooldown > 0:
      dec sim.robots[i].kickCooldown

  if sim.lastTouch.seat >= 0:
    inc sim.stats[Seat(sim.lastTouch.seat and 1)].possessionTicks

  # Stalemate: StalemateBox is a HALF-width, so the ball has to leave a
  # 3 m x 3 m square centred on the anchor to reset the counter. It cannot
  # do that in one tick from the anchor (BallMaxSpeed is 1.04 m/tick), so a
  # single frame of jitter can never reset it.
  let
    dx = sim.ball.x - sim.anchorX
    dy = sim.ball.y - sim.anchorY
  if abs(dx) <= StalemateBox and abs(dy) <= StalemateBox:
    inc sim.stalemateTicks
  else:
    sim.anchorX = sim.ball.x
    sim.anchorY = sim.ball.y
    sim.stalemateTicks = 0
  if sim.stalemateTicks >= int32(sim.config.stalemateTicks):
    sim.neutralDrop()

  if sim.physicsGuardTripped():
    sim.finishGame(reasonFault, erSimFault)
    return

  # Cosmetics (never hashed).
  sim.trail.add TrailPoint(x: sim.ball.x, y: sim.ball.y,
    tick: int32(sim.tickCount), seat: sim.lastTouch.seat)
  if sim.tickCount mod 3 == 0:
    for i in 0 ..< RobotCount:
      sim.paint.add PaintDot(x: sim.robots[i].x, y: sim.robots[i].y,
        robot: int32(i))
  sim.trimFx()

  # Turn end.
  let elapsed = sim.tickCount - sim.gameStartTick
  if (elapsed + 1) mod sim.turnTicks() == 0:
    sim.emitEvent(DirectiveEvent, amount = sim.currentTurn(),
      content = "turn_end")
    if abs(sim.goalDiff(Azure)) >= sim.config.mercyGoalDiff:
      sim.finishGame(reasonComplete, erMercy)
      return
  if elapsed + 1 >= sim.config.maxTicks:
    sim.finishGame(reasonComplete, erFullTime)

proc step*(
  sim: var SimServer,
  inputs: openArray[InputState],
  prevInputs: openArray[InputState]
) =
  ## Advances the sim by one tick. `prevInputs` is accepted for parity with
  ## ctf's signature (the replay path builds both); cogball's actuators are
  ## level-triggered, so nothing here reads it.
  discard prevInputs
  case sim.phase
  of Lobby:
    if sim.players.len < sim.config.minPlayers:
      inc sim.lobbyWaitTimer
      sim.startWaitTimer = 0
      sim.logLobbyWaiting()
    else:
      sim.logLobbyWaiting()
      if sim.startWaitTimer <= 0:
        sim.startWaitTimer = max(1, sim.config.startWaitTicks)
      sim.logLobbyCountdown()
      dec sim.startWaitTimer
      if sim.startWaitTimer <= 0:
        sim.startGame()
  of Playing:
    if int32(sim.tickCount) < sim.freezeUntil:
      sim.stepPlaying(ZeroInputs)
    else:
      sim.stepPlaying(inputs)
  of GameOver:
    if sim.gameOverTimer > 0:
      dec sim.gameOverTimer
  inc sim.tickCount

proc wallClockStop*(sim: var SimServer) =
  ## The engine's hard stop. The score at this instant stands, the replay is
  ## complete up to this tick, and the game-over frame is written.
  if sim.phase == Playing:
    sim.finishGame(reasonDeadline, erWallClock)

proc hostErrorStop*(sim: var SimServer) =
  if sim.phase != GameOver:
    sim.finishGame(reasonFault, erHostError)
