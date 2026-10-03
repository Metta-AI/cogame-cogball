## Presentation-only value boundary. No config, coach text, player identity,
## provider evidence, RNG reference or future replay records cross this seam.
import std/json
import cogball/sim

type
  BodyView* = object
    x*, y*, heading*: int32
  ReplayView* = object
    tick*: int
    phase*: GamePhase
    score*: array[2, int32]
    robots*: array[RobotCount, BodyView]
    ball*: BodyView

proc snapshot*(sim: SimServer): ReplayView =
  result.tick = sim.tickCount
  result.phase = sim.phase
  for seat in Seat:
    result.score[ord(seat)] = sim.stats[seat].goals
  for i, robot in sim.robots:
    result.robots[i] = BodyView(x: robot.x, y: robot.y, heading: robot.headingQ)
  result.ball = BodyView(x: sim.ball.x, y: sim.ball.y)

proc publicJson*(view: ReplayView): JsonNode =
  result = %*{"tick": view.tick, "phase": $view.phase,
    "score": view.score, "ball": [view.ball.x, view.ball.y], "robots": []}
  for i, robot in view.robots:
    result["robots"].add(%*{"slot": i,
      "alias": (if i < RobotsPerSeat: "AZ-" else: "CR-") & $(i mod RobotsPerSeat + 1),
      "position": [robot.x, robot.y], "heading": robot.heading})

proc proofJson*(sim: SimServer): JsonNode =
  ## The hash is a decimal string: JS numbers cannot represent uint64 exactly.
  result = snapshot(sim).publicJson()
  result["hash"] = %($sim.gameHash())
