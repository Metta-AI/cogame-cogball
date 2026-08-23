## Broadcast-side art: the wheeled-rig compositor and the ball/turf bakes.
##
## Everything here is BROADCAST-ONLY: no sim state, nothing in gameHash, no
## GameVersion bump for changes. The robots are the shipped real art —
## `data/rig_real/blue` (Azure) and `data/rig_real/red` (Crimson) — the same
## nine-segment CvC rig coworld-ctf draws, composed here into ONE sprite per
## (livery, heading step) because a cogball robot has no turret to swivel: its
## body and its heading are the same thing.

import
  std/[math, os, tables],
  pixie,
  sim_types

type
  RigSeg = enum
    rsLegFL, rsLegFR, rsLegRear, rsWheelL, rsWheelR, rsWheelRear,
    rsArmL, rsArmR, rsHead

const
  RigSteps* = 16              ## baked heading steps (16 brads apart).
  RigCanvas* = 64             ## px square robot sprite canvas at 1x.
  RobotBodyPx* = 30           ## drawn body size on the map at 1x; the collision
                              ## circle is 1.1 m = 27.5 map px, so the art reads
                              ## a touch larger than the hull, as it should.
  BallSpritePx* = 20          ## 0.7 m diameter = 17.5 map px, plus the rim.
  MasterFrame = 192.0
  MasterBody = 99.0           ## the solid body span in the 192 px master frame.
  RigHub: tuple[x, y: float] = (96.0, 88.0)

var
  rigImages: array[Seat, array[RigSeg, Image]]
  rigLoaded: array[Seat, bool]
  rigCache = initTable[int, seq[uint8]]()
  ballCache = initTable[int, seq[uint8]]()
  discCache = initTable[int, seq[uint8]]()

proc gameDir*(): string =
  ## Assets resolve against the process working directory, exactly as ctf does
  ## (the Dockerfile copies `data/` next to the binary and the emscripten build
  ## preloads it as `data`).
  getCurrentDir()

proc segPath(seg: RigSeg): string =
  case seg
  of rsHead: "head"
  of rsArmL: "arm_l"
  of rsArmR: "arm_r"
  of rsLegFL: "leg_fl"
  of rsLegFR: "leg_fr"
  of rsLegRear: "leg_rear"
  of rsWheelL: "wheel_l"
  of rsWheelR: "wheel_r"
  of rsWheelRear: "wheel_rear"

proc liveryDir(seat: Seat): string =
  ## Azure rides the shipped BLUE rig, Crimson the RED one. That is why the
  ## design renamed the alias from "Magenta": no recolouring, no placeholder.
  if seat == Azure: "blue" else: "red"

proc ensureRigLoaded(seat: Seat) =
  if rigLoaded[seat]:
    return
  let dir = gameDir() / "data" / "rig_real" / liveryDir(seat)
  for seg in RigSeg:
    rigImages[seat][seg] = readImage(dir / segPath(seg) & ".png")
  rigLoaded[seat] = true

proc canvasToPixels(canvas: Image): seq[uint8] =
  ## Straight-alpha RGBA for the Sprite v1 protocol (pixie stores premultiplied).
  result = newSeq[uint8](canvas.width * canvas.height * 4)
  for i in 0 ..< canvas.width * canvas.height:
    let c = canvas.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc rigPixels*(seat: Seat, step: int, renderScale = 1): seq[uint8] =
  ## The whole robot at one heading step, hub-centred in a RigCanvas sprite.
  ## Cached for the life of the process: 2 liveries x 16 steps.
  let
    b = ((step mod RigSteps) + RigSteps) mod RigSteps
    key = (ord(seat) * RigSteps + b) * 8 + renderScale
  if rigCache.hasKey(key):
    return rigCache[key]
  ensureRigLoaded(seat)
  let
    outCanvas = RigCanvas * renderScale
    s = float(RobotBodyPx) / MasterBody * float(renderScale)
    centre = float32(outCanvas) / 2
    # The masters face SOUTH, so the -90 degrees turn makes the face lead the
    # heading. Angle increases counter-clockwise; screen y is down, so negate.
    angle = float(b) * 2.0 * PI / float(RigSteps)
    mat = translate(vec2(centre, centre)) *
      rotate(float32(-angle - PI / 2.0)) *
      scale(vec2(float32(s), float32(s))) *
      translate(vec2(float32(-RigHub.x), float32(-RigHub.y)))
  var canvas = newImage(outCanvas, outCanvas)
  # A soft drop shadow first, then the segments back-to-front: legs and wheels,
  # then the shoulders, then the head cube on top so no hub hole shows.
  let shadow = newImage(outCanvas, outCanvas)
  let shadowCtx = newContext(shadow)
  shadowCtx.fillStyle = rgba(0, 0, 0, 70)
  shadowCtx.fillEllipse(
    vec2(centre, centre + float32(RobotBodyPx) * float32(renderScale) * 0.22),
    float32(RobotBodyPx) * float32(renderScale) * 0.48,
    float32(RobotBodyPx) * float32(renderScale) * 0.30)
  shadow.blur(2.0 * float32(renderScale))
  canvas.draw(shadow)
  for seg in RigSeg:
    canvas.draw(rigImages[seat][seg], mat)
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
  let key = size * 100_000_000 + int(colour.r) * 1_000_000 +
    int(colour.g) * 10_000 + int(colour.b) * 100 + int(colour.a) div 4
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

proc seatColour*(seat: Seat): ColorRGBA {.inline.} =
  if seat == Azure: AzureColor else: CrimsonColor
