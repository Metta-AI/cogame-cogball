## Sprite-label vocabulary: the machine-readable CONTRACT between the engine
## (the producer, `global.nim`) and anything reading the wire — the seat
## streams, the inspector, the sprite-dedup audit.
##
## A label is not a debug tag: it is the observation schema. Labels are
## computed at render time and never serialized (flatty writes `SimServer`
## positionally, so replays carry no label bytes) and nothing type-checks a
## label string, so renaming one is silent. Hoisting the strings to consts
## makes producer and consumer share one definition.
##
## **This module must keep ZERO imports.** Kept from ctf verbatim in spirit.

const
  LabelPitch* = "pitch"
    ## One horizontal band of the baked turf. The board is banded so no single
    ## websocket frame exceeds the hosted replay's 1 MiB ceiling.
  LabelBall* = "ball"
    ## The match ball. Its object position IS the ball's map-pixel centre.
  LabelRobot* = "robot"
    ## A robot of either trio. The full label is `robot <id>`, e.g.
    ## `robot AZ-2` — the anonymous in-game identity, never a policy name.
  LabelSelfMarker* = "own robot"
    ## Marks one of the receiving seat's own robots. Player streams only.
  LabelOwnSeat* = "own seat"
    ## An invisible 1x1 marker naming the receiving seat's alias
    ## (`own seat Azure`). Player streams only; it is how a seat learns which
    ## trio is its own without ever seeing a real player name.
  LabelBallTrail* = "ball trail"
    ## One tapering segment of the last 45 ticks of ball positions, tinted by
    ## the last toucher's livery.
  LabelKickFx* = "kick"
    ## The expanding ring at a kick's contact point.
  LabelGoalFlash* = "goal flash"
    ## The full-canvas flash on a goal.
  LabelConfetti* = "goal confetti"
    ## One celebration particle in the scoring livery.
  LabelPaint* = "paint"
    ## Position-history turf paint: each robot's own hue, accumulating where it
    ## drove. Over 3:20 the keeper's arc, the back's shuttle and the striker's
    ## runs separate visually — roles emerging with no labels.
  LabelChrome* = "broadcast chrome"
    ## The reserved never-drawn 1x1 sprite whose LABEL carries the broadcast
    ## chrome JSON. It rides the binary sprite channel because that is the only
    ## channel that survives a hosted replay.

  ContractLabels*: array[11, string] = [
    LabelPitch, LabelBall, LabelRobot, LabelSelfMarker, LabelOwnSeat,
    LabelBallTrail, LabelKickFx, LabelGoalFlash, LabelConfetti, LabelPaint,
    LabelChrome
  ]
    ## The golden vocabulary. `tests/test_viewer.nim` asserts the renderer emits
    ## nothing outside it.
