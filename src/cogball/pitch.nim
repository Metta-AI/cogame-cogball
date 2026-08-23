## The pitch: a fixed 44 m x 25 m walled indoor field. Geometry constants, the
## collision half-planes, the goal test and the neutral-drop spots — all in
## integer micrometres, all pure functions.
##
## ctf generates, validates, mirrors and pools its terrain; cogball has exactly
## one board, so `arena.nim`, `map_art.nim`, `map_pool.nim`, `mapgen_styles.nim`
## and the whole editor/mapkit tree are DELETED rather than ported. The turf
## BAKE lives in `global.nim` with the rest of the rendering: this module is
## inside the float-free grep guard (tests/test_determinism.nim) and pixie is a
## float API.

import sim_types

const
  Posts*: array[4, tuple[x, y: int32]] = [
    (PitchXMin, GoalYMin),
    (PitchXMin, GoalYMax),
    (PitchXMax, GoalYMin),
    (PitchXMax, GoalYMax)
  ]
    ## The four goalposts, static circles of PostRadius at the mouth corners.

  DropSpots*: array[4, tuple[x, y: int32]] = [
    (11_000_000'i32, 6_500_000'i32),
    (11_000_000'i32, 18_500_000'i32),
    (33_000_000'i32, 6_500_000'i32),
    (33_000_000'i32, 18_500_000'i32)
  ]
    ## Neutral-drop spots. Deliberately never in front of a goal, so the drop
    ## needs no goal-mouth exemption.

proc inGoalBand*(y: int32): bool {.inline.} =
  ## True when a y lies in the goal-mouth corridor, the band a body may pass
  ## through the goal plane in.
  y >= GoalYMin and y <= GoalYMax

proc xBounds*(y, radius: int32): tuple[lo, hi: int32] {.inline.} =
  ## The x range a body of `radius` may occupy at height `y`. Inside the mouth
  ## band the range opens all the way through the goal into the back wall;
  ## elsewhere it stops at the goal line.
  if y >= GoalYMin + radius and y <= GoalYMax - radius:
    (radius, WorldW - radius)
  else:
    (PitchXMin + radius, PitchXMax - radius)

proc yBounds*(x, radius: int32): tuple[lo, hi: int32] {.inline.} =
  ## The y range a body of `radius` may occupy at abscissa `x`. Inside a goal
  ## box the range narrows to the mouth; on the pitch it is the touchlines.
  if x < PitchXMin or x > PitchXMax:
    (GoalYMin + radius, GoalYMax - radius)
  else:
    (radius, WorldH - radius)

proc inPitch*(x, y: int32): bool {.inline.} =
  ## True when a POINT is on the playing surface or inside a goal box. The
  ## physics guard (`sim_fault`) uses this on every body every tick.
  if x >= PitchXMin and x <= PitchXMax:
    return y >= 0 and y <= WorldH
  if x >= 0 and x <= WorldW:
    return y >= GoalYMin and y <= GoalYMax
  false

proc inOwnPenaltyArea*(seat: Seat, x, y: int32): bool {.inline.} =
  ## The penalty area exists only for save attribution — no special powers.
  let dy = if y >= CentreY: y - CentreY else: CentreY - y
  if dy > PenaltyHalfH:
    return false
  if seat == Azure:
    x <= PenaltyDepth
  else:
    x >= WorldW - PenaltyDepth

proc goalScoredBy*(ballX, ballY: int32): int32 =
  ## The seat that has just scored, or -1. A goal is scored the moment the
  ## ball CENTRE crosses the plane inside the mouth band.
  if ballY < GoalYMin or ballY > GoalYMax:
    return -1
  if ballX <= PitchXMin:
    return int32(ord(Crimson))
  if ballX >= PitchXMax:
    return int32(ord(Azure))
  -1

proc onBoards*(x, y: int32): bool {.inline.} =
  ## The ball is "on the boards" — the absorbing corner state the round-1 build
  ## discovered — when it hugs a touchline or a goal line, EXCEPT inside the
  ## goal-mouth corridor, where a shot at goal must never be redirected.
  if y >= GoalYMin and y <= GoalYMax:
    return false
  y < 2_000_000'i32 or y > 23_000_000'i32 or
    x < 4_000_000'i32 or x > 40_000_000'i32

proc nearestDropSpot*(x, y: int32): tuple[x, y: int32] =
  ## The drop spot nearest a point, in the fixed table order so ties resolve
  ## deterministically toward the earlier entry.
  var
    best = DropSpots[0]
    bestD = high(int64)
  for spot in DropSpots:
    let
      dx = int64(spot.x) - int64(x)
      dy = int64(spot.y) - int64(y)
      d = dx * dx + dy * dy
    if d < bestD:
      bestD = d
      best = spot
  best
