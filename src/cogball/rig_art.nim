## Broadcast-side art: the cog sprite compositor and the ball/turf bakes.
##
## Everything here is BROADCAST-ONLY: no sim state, nothing in gameHash, no
## GameVersion bump for changes. The robots are nano-banana (Gemini) renders
## of the canonical Softmax cog in two football kits — `data/art/cog_azure.png`
## (blue #7 jersey, headband, keeper gloves) and `data/art/cog_crimson.png`
## (red #9 jersey, crested helmet with a white plume, shin guards) — produced
## by `scripts/art/split_cog_sheet.py` from `scripts/art/source/cogs_sheet.png`.
## The sprite is drawn UPRIGHT with its feet on the robot's position, so the
## kit always reads; the heading is a tick on a team-coloured ground ellipse
## under the wheels, baked once per (livery, heading step).

import
  std/[math, os, tables],
  pixie,
  sim_types

const
  RigSteps* = 16              ## baked heading steps (16 brads apart).
  RigCanvas* = 88             ## px square robot sprite canvas at 1x.
  RobotBodyPx* = 30           ## hull footprint on the map at 1x: the collision
                              ## circle is 1.1 m = 27.5 map px, and the ground
                              ## ellipse under the cog is sized against it.
  CogSpritePx* = 48           ## the upright cog sprite's height at 1x.
  CogFeetDrop = 8             ## sprite bottom edge sits this far below the
                              ## robot's position (the feet straddle the ring).
  CogRingDrop = 4             ## the ground ellipse's centre, below the position.
  CogHeadTop* = CogSpritePx - CogFeetDrop
                              ## how far above the position the sprite reaches.
  BallSpritePx* = 20          ## 0.7 m diameter = 17.5 map px, plus the rim.

var
  cogImages: array[Seat, Image]
  cogLoaded: array[Seat, bool]
  rigCache = initTable[int, seq[uint8]]()
  ballCache = initTable[int, seq[uint8]]()
  discCache = initTable[(int, uint8, uint8, uint8, uint8), seq[uint8]]()
    ## Keyed by a TUPLE, not a packed int: `int` is 32 bits under
    ## --cpu:wasm32 and a size-major packing overflows it.

proc gameDir*(): string =
  ## Assets resolve against the process working directory, exactly as ctf does
  ## (the Dockerfile copies `data/` next to the binary and the emscripten build
  ## preloads it as `data`).
  getCurrentDir()

proc liveryFile(seat: Seat): string =
  if seat == Azure: "cog_azure.png" else: "cog_crimson.png"

proc ensureCogLoaded(seat: Seat) =
  if cogLoaded[seat]:
    return
  cogImages[seat] = readImage(gameDir() / "data" / "art" / liveryFile(seat))
  cogLoaded[seat] = true

proc canvasToPixels(canvas: Image): seq[uint8] =
  ## Straight-alpha RGBA for the Sprite v1 protocol (pixie stores premultiplied).
  result = newSeq[uint8](canvas.width * canvas.height * 4)
  for i in 0 ..< canvas.width * canvas.height:
    let c = canvas.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc seatColour*(seat: Seat): ColorRGBA {.inline.} =
  if seat == Azure: AzureColor else: CrimsonColor

proc rigPixels*(seat: Seat, step: int, renderScale = 1): seq[uint8] =
  ## The whole robot at one heading step, position-centred in a RigCanvas
  ## sprite: shadow, team ground ellipse with a heading tick, then the upright
  ## cog with its feet on the ring. Cached for the life of the process:
  ## 2 liveries x 16 steps.
  let
    b = ((step mod RigSteps) + RigSteps) mod RigSteps
    key = (ord(seat) * RigSteps + b) * 8 + renderScale
  if rigCache.hasKey(key):
    return rigCache[key]
  ensureCogLoaded(seat)
  let
    k = float32(renderScale)
    outCanvas = RigCanvas * renderScale
    centre = float32(outCanvas) / 2
    ringY = centre + float32(CogRingDrop) * k
    ringRx = float32(RobotBodyPx) * k * 0.5
    ringRy = ringRx * 0.48
    # Angle increases counter-clockwise; screen y is down, so negate.
    angle = float32(b) * 2.0'f32 * float32(PI) / float32(RigSteps)
  var canvas = newImage(outCanvas, outCanvas)
  let shadow = newImage(outCanvas, outCanvas)
  let shadowCtx = newContext(shadow)
  shadowCtx.fillStyle = rgba(0, 0, 0, 70)
  shadowCtx.fillEllipse(vec2(centre, ringY), ringRx * 1.1, ringRy * 1.1)
  shadow.blur(2.0 * k)
  canvas.draw(shadow)
  let ctx = newContext(canvas)
  ctx.strokeStyle = seatColour(seat)
  ctx.lineWidth = 2.5 * k
  ctx.strokeEllipse(vec2(centre, ringY), ringRx, ringRy)
  # the heading tick: from the ring centre out along the heading, projected
  # onto the ground ellipse so it reads as lying on the turf
  ctx.strokeStyle = rgba(242, 232, 216, 200)
  ctx.lineWidth = 2.0 * k
  ctx.strokeSegment(segment(
    vec2(centre, ringY),
    vec2(centre + cos(angle) * ringRx * 1.4, ringY - sin(angle) * ringRy * 1.4)))
  let
    img = cogImages[seat]
    s = float32(CogSpritePx) * k / float32(img.height)
    w = float32(img.width) * s
    bottom = centre + float32(CogFeetDrop) * k
    mat = translate(vec2(centre - w / 2, bottom - float32(CogSpritePx) * k)) *
      scale(vec2(s, s))
  canvas.draw(img, mat)
  result = canvasToPixels(canvas)
  rigCache[key] = result

proc headingStep*(brads: int32): int =
  ## Nearest of the RigSteps baked headings.
  ((int(brads) + AimBradsTurn div (RigSteps * 2)) * RigSteps div
    AimBradsTurn) mod RigSteps

proc ballPixels*(renderScale = 1): seq[uint8] =
  ## A baked shaded sphere with a rolling seam — no solid-colour placeholder.
  if ballCache.hasKey(renderScale):
    return ballCache[renderScale]
  let
    size = BallSpritePx * renderScale
    r = float32(size) / 2.0
  var canvas = newImage(size, size)
  let ctx = newContext(canvas)
  ctx.fillStyle = rgba(20, 20, 18, 90)
  ctx.fillEllipse(vec2(r, r + r * 0.16), r * 0.92, r * 0.72)
  ctx.fillStyle = BallColor
  ctx.fillEllipse(vec2(r, r), r * 0.86, r * 0.86)
  ctx.fillStyle = rgba(196, 198, 190, 255)
  ctx.fillEllipse(vec2(r, r + r * 0.26), r * 0.80, r * 0.52)
  ctx.fillStyle = rgba(36, 38, 36, 235)
  ctx.fillEllipse(vec2(r * 0.72, r * 0.78), r * 0.19, r * 0.15)
  ctx.fillEllipse(vec2(r * 1.32, r * 1.16), r * 0.15, r * 0.12)
  ctx.fillStyle = rgba(255, 255, 255, 190)
  ctx.fillEllipse(vec2(r * 0.74, r * 0.62), r * 0.24, r * 0.17)
  result = canvasToPixels(canvas)
  ballCache[renderScale] = result

proc discPixels*(size: int, colour: ColorRGBA, feather = true): seq[uint8] =
  ## A soft round dot: the ball trail, the turf paint and the goal confetti all
  ## draw from this one bake, keyed by (size, colour).
  let key = (size, colour.r, colour.g, colour.b, colour.a)
  if discCache.hasKey(key):
    return discCache[key]
  var canvas = newImage(max(1, size), max(1, size))
  let
    ctx = newContext(canvas)
    r = float32(size) / 2.0
  ctx.fillStyle = colour
  ctx.fillEllipse(vec2(r, r), r * (if feather: 0.86 else: 1.0),
    r * (if feather: 0.86 else: 1.0))
  if feather:
    canvas.blur(max(0.6'f32, r * 0.20))
  result = canvasToPixels(canvas)
  discCache[key] = result

proc ringPixels*(size: int, colour: ColorRGBA, thickness: float32): seq[uint8] =
  ## A kick-impact ring. Not cached by colour alpha alone, so the caller keys
  ## it by stage.
  var canvas = newImage(max(1, size), max(1, size))
  let
    ctx = newContext(canvas)
    r = float32(size) / 2.0
  ctx.strokeStyle = colour
  ctx.lineWidth = thickness
  ctx.strokeEllipse(vec2(r, r), r - thickness, r - thickness)
  canvasToPixels(canvas)

proc hueColour*(hue: int, alpha: uint8): ColorRGBA =
  ## The per-robot paint hue (RobotHues), as an RGBA at a given alpha.
  let c = ColorHSL(h: float32(hue), s: 62.0, l: 46.0).asRgb()
  rgba(c.r, c.g, c.b, alpha)
