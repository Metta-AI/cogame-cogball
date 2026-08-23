## The two scripted baselines. Both emit the SAME directive object on the same
## 5 s cadence as an LLM coach, so their output is legal by construction and
## directly comparable — which is what makes the bounded-orders test in
## tests/test_baselines.nim meaningful.
##
## `formation` is the certification player, the fallback directive when the LLM
## fails twice, and the default for a seat that registers neither field.
## `swarm` is the second filler: deliberately weaker and different in shape.

import
  std/strutils,
  sim, directives

## The tuning constants are `{.intdefine.}` so the grid harness can sweep them
## from the command line (`-d:CogballKeeperArc=2500000`) without editing the
## source. The harness is `tools/tune_baselines.{nim,sh}` and every value below
## is the winner of a committed, reproducible sweep: 48 formation-vs-swarm
## matches per row, both sides played. The full tables — including the two
## places these numbers disagree with the design note, and a disjoint-seed
## holdout that says how much of each margin is noise — are in
## docs/tuning/baseline-grid.md. Do not change one of these without re-running
## the sweep and updating that file.
const
  KeeperArc* {.intdefine: "CogballKeeperArc".} = 2_000_000
    ## micrometres in front of the own goal line. Swept 1/1.5/2/3/4 m: 2 m
    ## wins on both seed lists (63/96 and 61/96) and is the only value with no
    ## goalless match on either, because a keeper further out is a keeper the
    ## second attacker walks around and a keeper on the line concedes the
    ## rebound. The design note's 3 m loses on both lists.
  KeeperYSpan* {.intdefine: "CogballKeeperYSpan".} = 2_600_000
  StrikerRange* {.intdefine: "CogballStrikerRange".} = 9_000_000
    ## how close the ball has to be, in its OWN half, before the nearest robot
    ## strikes instead of merely chasing. Swept 4/6/9/12/15/20/40 m: 9 m wins
    ## the default list (63/96 vs 6 m's 58/96) and is never the worst of
    ## 6/9/12 on either list. The 6-to-12 m band is inside the seed noise —
    ## see the holdout table — which is exactly why the number and its
    ## uncertainty are both written down.
  BackPull* {.intdefine: "CogballBackPull".} = 1_500_000
    ## Swept 0/1.5/3 m: 1.5 m wins 63/96 against 50 and 56.
  WingLead* {.intdefine: "CogballWingLead".} = 7_000_000
    ## Swept 4/7/10 m: 7 m wins 63/96 against 60 and 48.
  WingWide* {.intdefine: "CogballWingWide".} = 5_000_000
    ## Swept 2.5/5/7.5 m: 5 m wins 63/96 against 49 and 57.
  SupportAlwaysRuns* {.intdefine: "CogballSupportAlwaysRuns".} = 0
    ## 1 = the third robot runs the channel even while the ball is in its own
    ## half, instead of shielding the middle. Swept: shielding wins 63/96
    ## against 50/96.

proc ballInOwnHalf*(sim: SimServer, seat: Seat): bool {.inline.} =
  if attackDir(seat) > 0: sim.ball.x < CentreX else: sim.ball.x > CentreX

proc deepestRobot*(sim: SimServer, seat: Seat): int =
  ## The robot nearest its own goal; ties by ascending robot index. Exported
  ## so tests/test_baselines.nim can assert the role labels against the same
  ## choice the baselines make, rather than re-deriving it.
  let own = ownGoalX(seat)
  var
    best = firstRobotOf(seat)
    bestD = high(int64)
  for slot in 0 ..< RobotsPerSeat:
    let
      i = firstRobotOf(seat) + slot
      d = abs(int64(sim.robots[i].x) - int64(own))
    if d < bestD:
      bestD = d
      best = i
  best

proc closestToBall(sim: SimServer, seat: Seat, skip: int): int =
  var
    best = -1
    bestD = high(int64)
  for slot in 0 ..< RobotsPerSeat:
    let i = firstRobotOf(seat) + slot
    if i == skip:
      continue
    let
      dx = int64(sim.ball.x) - int64(sim.robots[i].x)
      dy = int64(sim.ball.y) - int64(sim.robots[i].y)
      d = dx * dx + dy * dy
    if d < bestD:
      bestD = d
      best = i
  best

proc keeperTarget(sim: SimServer, seat: Seat): tuple[x, y: int32] =
  let
    x = ownGoalX(seat) + int32(KeeperArc) * attackDir(seat)
    y = CentreY + clamp((sim.ball.y - CentreY) div 3,
      -int32(KeeperYSpan), int32(KeeperYSpan))
  (x, y)

proc formationDirective*(sim: SimServer, seat: Seat, turn: int): Directive =
  ## The reference shape: one keeper on the arc, the nearest robot on the ball,
  ## the third either shielding the middle or running the channel.
  result = emptyDirective(seat)
  result.turn = int32(turn)
  result.source = dsScripted
  result.note = "keeper home, nearest on the ball, third in the channel"
  let
    base = firstRobotOf(seat)
    keeper = sim.deepestRobot(seat)
    striker = sim.closestToBall(seat, keeper)
  # The third robot is reached by elimination in the loop below (the `else`
  # branch), so it needs no separate search.
  for slot in 0 ..< RobotsPerSeat:
    let i = base + slot
    var order = RobotOrder(kick: kickAuto, passTo: -1)
    if i == keeper:
      let target = sim.keeperTarget(seat)
      order.role = roleKeeper
      order.intent = inHold
      order.targetX = target.x
      order.targetY = target.y
      order.say = "holding the arc"
    elif i == striker:
      order.role = roleStriker
      order.targetX = sim.ball.x
      order.targetY = sim.ball.y
      let
        dist = distI(sim.ball.x - sim.robots[i].x, sim.ball.y - sim.robots[i].y)
        inOpponentHalf = not sim.ballInOwnHalf(seat)
      if inOwnPenaltyArea(seat, sim.ball.x, sim.ball.y):
        order.intent = inClear
        order.say = "get it clear"
      elif inOpponentHalf or dist <= int32(StrikerRange):
        order.intent = inShoot
        order.say = "having a go"
      else:
        order.intent = inChase
        order.say = "closing in"
    else:
      order.role = roleBack
      if sim.ballInOwnHalf(seat) and SupportAlwaysRuns == 0:
        let
          own = ownGoalX(seat)
          midX = int32((int64(sim.ball.x) + int64(own)) div 2)
          side = if sim.ball.y >= CentreY: -int32(BackPull)
                 else: int32(BackPull)
        order.intent = inHold
        order.targetX = midX
        order.targetY = clamp(sim.ball.y + side, 1_000_000'i32,
          WorldH - 1_000_000'i32)
        order.say = "screening the middle"
      else:
        order.role = roleWing
        order.intent = inIntercept
        let side = if sim.ball.y >= CentreY: -int32(WingWide)
                   else: int32(WingWide)
        order.targetX = clamp(sim.ball.x + int32(WingLead) * attackDir(seat),
          PitchXMin + 1_000_000'i32, PitchXMax - 1_000_000'i32)
        order.targetY = clamp(CentreY + side, 1_000_000'i32,
          WorldH - 1_000_000'i32)
        order.say = "running the channel"
    result.robots[slot] = order

proc swarmDirective*(sim: SimServer, seat: Seat, turn: int): Directive =
  ## Everyone chases. The deepest robot minds the goal only while the ball is
  ## in its own half. Loses to `formation`, which is the point: the ladder
  ## needs a spread.
  ##
  ## Roles are reported striker/striker/back: the deepest robot is the `back`
  ## whatever the ball is doing, because the ROLE is what the feed and the
  ## seat view read as "who is this robot", and a label that flickers between
  ## striker and back every time the ball crosses the halfway line describes
  ## nothing. Only its INTENT depends on the ball's half.
  result = emptyDirective(seat)
  result.turn = int32(turn)
  result.source = dsScripted
  result.note = "everyone on the ball"
  let
    base = firstRobotOf(seat)
    keeper = sim.deepestRobot(seat)
    guard = sim.ballInOwnHalf(seat)
  for slot in 0 ..< RobotsPerSeat:
    let i = base + slot
    var order = RobotOrder(kick: kickAuto, passTo: -1)
    order.role = if i == keeper: roleBack else: roleStriker
    if i == keeper and guard:
      let target = sim.keeperTarget(seat)
      order.intent = inHold
      order.targetX = target.x
      order.targetY = target.y
      order.say = "minding the goal"
    else:
      order.intent = inChase
      order.targetX = sim.ball.x
      order.targetY = sim.ball.y
      order.say = "on it"
    result.robots[slot] = order

proc baselineDirective*(
  sim: SimServer,
  seat: Seat,
  name: string,
  turn: int
): Directive =
  ## Dispatch by baseline name. An unknown name is `formation` — a seat that
  ## sets neither PLAYER_PROMPT nor PLAYER_SCRIPTED plays it too.
  if name.strip().toLowerAscii() == "swarm":
    sim.swarmDirective(seat, turn)
  else:
    sim.formationDirective(seat, turn)
