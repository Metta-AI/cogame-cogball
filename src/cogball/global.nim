## The board renderer: pitch, robots, ball, trail, kick FX, goal celebration
## and the position-history turf paint, composed as Sprite v1 sprite/object
## messages.
##
## This replaces ctf's `global.nim` (7 700 lines of fog-of-war, vision cones,
## first-person raycasting, killfeed art and item sprites). Soccer is a
## perfect-information sport, so there is NO fog: the two builders differ only
## in the self markers and the seat's own-alias marker.
##
## Floats are legal here — rendering never enters `gameHash`, exactly as in
## ctf. The turf bake lives here rather than in `pitch.nim` because that module
## sits inside the float-free grep guard and pixie is a float API.

import
  std/[math, tables],
  pixie,
  bitworld/spriteprotocol,
  sim, labels, rig_art

const
  BoardScale* = 2
    ## Board pixels per LOGICAL map pixel. The chrome reports this as `bs` and
    ## converts board <-> world with it. 2 is comfortably inside the wasm32
    ## viewer's address space: the whole 2200x1250 turf bake is 11 MB.
  BoardW* = MapWidth * BoardScale
  BoardH* = MapHeight * BoardScale
  MapLayerId* = 0
  MapBandRows = 96 * BoardScale

  # ---- sprite ids -----------------------------------------------------------
  MapBandSpriteBase = 30
  MaxMapBands = 32
  BallSpriteId = 60
  RigSpriteBase = 100          ## 2 liveries x RigSteps
  TrailSpriteBase = 200        ## 3 tints x TrailStages
  PaintSpriteBase = 240        ## one per robot hue
  KickRingSpriteBase = 260     ## one per FX stage
  ConfettiSpriteBase = 280     ## one per seat
  GoalFlashSpriteId = 290
  SelfMarkerSpriteId = 292
  OwnSeatSpriteId = 294
  BroadcastChromeSpriteId* = 4090
    ## The reserved 1x1 sprite whose LABEL carries the chrome JSON. Kept from
    ## ctf, id and all, so the shared client code needs no change.

  # ---- object ids -----------------------------------------------------------
  MapBandObjectBase = 30
  RobotObjectBase = 1000
  BallObjectId = 1100
  SelfMarkerObjectBase = 1110
  OwnSeatObjectId = 1120
  TrailObjectBase = 2000
  TrailSlots = 45
  KickObjectBase = 2100
  KickSlots = 24
  ConfettiObjectBase = 2200
  ConfettiSlots = 120
  GoalFlashObjectId = 2400
  PaintObjectBase = 8000
  PaintSlots = 6000

  TrailStages = 8
  KickFxTicks* = 12
  GoalFxTicks* = 45
  KickRingStartPx = 9          ## 0.35 m at BoardScale.
  KickRingEndPx = 80           ## 1.6 m at BoardScale.

  BoardObjectPools: array[6, tuple[name: string, base, width: int]] = [
    ("map", MapBandObjectBase, MaxMapBands),
    ("robots", RobotObjectBase, RobotCount),
    ("trail", TrailObjectBase, TrailSlots),
    ("kickfx", KickObjectBase, KickSlots),
    ("confetti", ConfettiObjectBase, ConfettiSlots),
    ("paint", PaintObjectBase, PaintSlots)
  ]

type
  SpriteDefinition = ref object
    spriteId: int
    width, height: int
    label: string
    pixels: seq[uint8]

  GlobalViewerState* = object
    initialized*: bool
    mouseX*, mouseY*, mouseLayer*: int
    mouseDown*: bool
    clickPending*: bool
    selectedJoinOrder*: int
    povJoinOrder*: int
    povSelectPending*: int
    scrubbingReplay*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]
    momentumSent*: bool
    fpMapSent*: bool
    paintSent*: int            ## append-only cursor into sim.paint.
    spriteDefs: seq[SpriteDefinition]

  PlayerViewerState* = ref object
    initialized*: bool
    sentPlacements*: seq[array[12, uint8]]
    paintSent*: int
    spriteDefs: seq[SpriteDefinition]

proc boardObjectPoolName*(objectId: int): string =
  ## Names the fixed object pool an object id belongs to, for traffic metrics.
  for (name, base, width) in BoardObjectPools:
    if objectId >= base and objectId < base + width:
      return name
  "core"

proc boardRenderScaleFor*(mapWidth, mapHeight: int): int =
  ## The board's supersample factor. Fixed here: cogball has exactly one board
  ## and it is small enough to render at BoardScale on every target.
  discard mapWidth
  discard mapHeight
  BoardScale

proc initGlobalViewerState*(): GlobalViewerState =
  result.mouseLayer = MapLayerId
  result.selectedJoinOrder = -1
  result.povJoinOrder = -1
  result.povSelectPending = -2   ## -2 = no request; -1 = clear; >= 0 = slot.
  result.replaySeekTick = -1
  result.replayCommands = @[]

proc initPlayerViewerState*(): PlayerViewerState =
  new(result)

# --------------------------------------------------------------------------
# Client -> server messages
# --------------------------------------------------------------------------

proc applyGlobalViewerMessage*(state: var GlobalViewerState, message: string) =
  ## Applies one or more global protocol client messages. Whole-string
  ## commands (`s:<tick>`, `v:<slot>`) are intercepted before the legacy
  ## char-by-char transport path, so a multi-digit tick is never mangled into
  ## speed keystrokes. Kept from ctf.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientMouseMoveMessage:
      state.mouseX = item.x
      state.mouseY = item.y
      state.mouseLayer = if item.hasLayer: item.layer else: MapLayerId
    of SpriteClientMouseButtonMessage:
      if item.button == 0x01'u8:
        state.mouseDown = item.down
        if state.mouseDown:
          state.clickPending = true
        else:
          state.scrubbingReplay = false
    of SpriteClientChatMessage:
      if item.text.len > 2 and item.text[0] == 's' and item.text[1] == ':':
        var tick = 0
        var ok = item.text.len > 2
        for i in 2 ..< item.text.len:
          if item.text[i] notin {'0' .. '9'}:
            ok = false
            break
          tick = tick * 10 + (ord(item.text[i]) - ord('0'))
        if ok:
          state.replaySeekTick = tick
      elif item.text.len > 2 and item.text[0] == 'v' and item.text[1] == ':':
        var slot = 0
        var ok = true
        var negative = false
        for i in 2 ..< item.text.len:
          if i == 2 and item.text[i] == '-':
            negative = true
            continue
          if item.text[i] notin {'0' .. '9'}:
            ok = false
            break
          slot = slot * 10 + (ord(item.text[i]) - ord('0'))
        if ok:
          state.povSelectPending = if negative: -slot else: slot
      else:
        for ch in item.text:
          state.replayCommands.add(ch)
    of SpriteClientInputMessage, SpriteClientReadyMessage,
        SpriteClientDebugSpriteMessage:
      discard

proc applyPlayerViewerMessage*(
  state: var PlayerViewerState,
  message: string,
  inputMask: var uint8,
  pressedMask: var uint8,
  chatText: var string
) =
  ## A seat sends NO inputs (the server computes every mask), so the input
  ## bits are read and dropped. Its ONE chat message is its registration; the
  ## server intercepts it and never writes it to the replay chat stream.
  ## ctf's 0x86 debug-sprite channel is deleted rather than left dangling.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      chatText.add(item.text)
    of SpriteClientInputMessage:
      pressedMask = 0
      inputMask = 0
    else:
      discard
  discard state

# --------------------------------------------------------------------------
# Packet plumbing (kept from ctf: generic, sprite-protocol level)
# --------------------------------------------------------------------------

proc chunkSpritePacket*(packet: seq[uint8], maxBytes: int): seq[seq[uint8]] =
  ## Splits one sprite-protocol packet into WS-frame-sized chunks at MESSAGE
  ## boundaries. The hosted replay closes any frame over 1 MiB (1009), and the
  ## client accumulates sprite/object state across binary messages, so N
  ## frames are equivalent to one — as long as no frame is cut mid-message.
  result = @[]
  if packet.len == 0:
    return
  var
    offset = 0
    chunkStart = 0
  while offset < packet.len:
    let msgStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:
      let clen = packet.readU32(offset + 6)
      offset += 10 + clen
      let llen = packet.readU16(offset)
      offset += 2 + llen
    of 0x02: offset += 11
    of 0x03: offset += 2
    of 0x04: discard
    of 0x05: offset += 5
    of 0x06: offset += 3
    else:
      break
    if offset - chunkStart > maxBytes and msgStart > chunkStart:
      result.add(packet[chunkStart ..< msgStart])
      chunkStart = msgStart
  if chunkStart < packet.len:
    result.add(packet[chunkStart ..< packet.len])

proc stripSpritePixels*(packet: seq[uint8], keepLabel = ""): seq[uint8] =
  ## Rewrites one packet for a Sprites Off (0x87) client: sprite definitions
  ## keep id, dimensions and label but ship a zero-length pixel payload.
  result = newSeqOfCap[uint8](packet.len)
  var offset = 0
  while offset < packet.len:
    let messageStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:
      let compressedLen = packet.readU32(offset + 6)
      let labelStart = offset + 10 + compressedLen
      let labelLen = packet.readU16(labelStart)
      let messageEnd = labelStart + 2 + labelLen
      var label = newString(labelLen)
      for i in 0 ..< labelLen:
        label[i] = char(packet[labelStart + 2 + i])
      if keepLabel.len > 0 and label == keepLabel:
        for i in messageStart ..< messageEnd:
          result.add(packet[i])
      else:
        for i in messageStart ..< offset + 6:
          result.add(packet[i])
        result.addU32(0)
        for i in labelStart ..< messageEnd:
          result.add(packet[i])
      offset = messageEnd
    of 0x02, 0x03, 0x04, 0x05, 0x06:
      offset += (
        case messageType
        of 0x02: 11
        of 0x03: 2
        of 0x05: 5
        of 0x06: 3
        else: 0
      )
      for i in messageStart ..< offset:
        result.add(packet[i])
    else:
      for i in messageStart ..< packet.len:
        result.add(packet[i])
      break

proc dedupObjectPlacements*(
  packet: seq[uint8],
  sentPlacements: var seq[array[12, uint8]]
): seq[uint8] =
  ## Drops Define Object messages whose full payload matches what this viewer
  ## already holds. The protocol is retained-mode, so re-sending an identical
  ## placement is pure wire noise. Kept from ctf.
  result = newSeqOfCap[uint8](packet.len)
  if sentPlacements.len == 0:
    sentPlacements.setLen(65536)
  var
    offset = 0
    keepStart = 0
  template flushKept(upTo: int) =
    if upTo > keepStart:
      let start = result.len
      result.setLen(start + upTo - keepStart)
      copyMem(addr result[start], unsafeAddr packet[keepStart],
        upTo - keepStart)
  while offset < packet.len:
    let messageStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:
      offset += 10 + packet.readU32(offset + 6)
      offset += 2 + packet.readU16(offset)
    of 0x02:
      var payload: array[12, uint8]
      copyMem(addr payload[0], unsafeAddr packet[offset], 11)
      payload[11] = 1
      offset += 11
      let objectId = int(payload[0]) or (int(payload[1]) shl 8)
      if sentPlacements[objectId] == payload:
        flushKept(messageStart)
        keepStart = offset
      else:
        sentPlacements[objectId] = payload
    of 0x03:
      sentPlacements[packet.readU16(offset)][11] = 0
      offset += 2
    of 0x04:
      zeroMem(addr sentPlacements[0], sentPlacements.len * 12)
    of 0x05, 0x06:
      offset += (if messageType == 0x05: 5 else: 3)
    else:
      offset = packet.len
  flushKept(packet.len)

# --------------------------------------------------------------------------
# The turf bake
# --------------------------------------------------------------------------

var
  pitchBands: seq[seq[uint8]]
  pitchBandRows: seq[int]

proc worldToBoard(x: int32): int {.inline.} =
  int((int64(x) * int64(BoardScale)) div int64(MapScale))

proc bakePitchImage*(): Image =
  ## Mown turf in two greens with 2.5 m stripes, painted white lines at 0.12 m,
  ## hatched goal nets with depth, and a dark vignette surround. Baked once at
  ## startup with pixie — already a dependency, already how ctf bakes its board.
  result = newImage(BoardW, BoardH)
  let
    ctx = newContext(result)
    px = float32(BoardScale) / float32(MapScale)   ## board px per micrometre.
  proc bx(x: int32): float32 = float32(x) * px
  proc by(y: int32): float32 = float32(y) * px
  let stroke = max(2.0'f32, bx(120_000'i32))
  # Surround.
  ctx.fillStyle = rgba(16, 24, 18, 255)
  ctx.fillRect(rect(0, 0, float32(BoardW), float32(BoardH)))
  # Mown stripes across the playing surface, 2.5 m wide.
  var stripe = 0
  var sx = PitchXMin
  while sx < PitchXMax:
    let w = min(2_500_000'i32, PitchXMax - sx)
    ctx.fillStyle = if stripe mod 2 == 0: TurfDark else: TurfLight
    ctx.fillRect(rect(bx(sx), 0, bx(w), float32(BoardH)))
    sx += w
    inc stripe
  # Goal boxes: darker turf behind the line.
  ctx.fillStyle = rgba(26, 58, 32, 255)
  ctx.fillRect(rect(0, by(GoalYMin), bx(PitchXMin), by(GoalYMax - GoalYMin)))
  ctx.fillRect(rect(bx(PitchXMax), by(GoalYMin), bx(WorldW - PitchXMax),
    by(GoalYMax - GoalYMin)))
  # Hatched nets with depth.
  ctx.strokeStyle = rgba(226, 232, 226, 120)
  ctx.lineWidth = max(1.0'f32, stroke * 0.35)
  var netY = GoalYMin
  while netY <= GoalYMax:
    ctx.strokeSegment(segment(vec2(0, by(netY)), vec2(bx(PitchXMin), by(netY))))
    ctx.strokeSegment(segment(vec2(bx(PitchXMax), by(netY)),
      vec2(float32(BoardW), by(netY))))
    netY += 500_000'i32
  var netX = 0'i32
  while netX <= PitchXMin:
    ctx.strokeSegment(segment(vec2(bx(netX), by(GoalYMin)),
      vec2(bx(netX), by(GoalYMax))))
    ctx.strokeSegment(segment(vec2(float32(BoardW) - bx(netX), by(GoalYMin)),
      vec2(float32(BoardW) - bx(netX), by(GoalYMax))))
    netX += 500_000'i32
  # Painted lines.
  ctx.strokeStyle = LineColor
  ctx.lineWidth = stroke
  proc line(x0, y0, x1, y1: int32) =
    ctx.strokeSegment(segment(vec2(bx(x0), by(y0)), vec2(bx(x1), by(y1))))
  line(PitchXMin, 0, PitchXMax, 0)
  line(PitchXMin, WorldH, PitchXMax, WorldH)
  line(PitchXMin, 0, PitchXMin, WorldH)
  line(PitchXMax, 0, PitchXMax, WorldH)
  line(CentreX, 0, CentreX, WorldH)
  ctx.strokeEllipse(vec2(bx(CentreX), by(CentreY)),
    bx(CentreCircleR), bx(CentreCircleR))
  # Penalty areas.
  line(PenaltyDepth, CentreY - PenaltyHalfH, PenaltyDepth, CentreY + PenaltyHalfH)
  line(PitchXMin, CentreY - PenaltyHalfH, PenaltyDepth, CentreY - PenaltyHalfH)
  line(PitchXMin, CentreY + PenaltyHalfH, PenaltyDepth, CentreY + PenaltyHalfH)
  line(WorldW - PenaltyDepth, CentreY - PenaltyHalfH,
    WorldW - PenaltyDepth, CentreY + PenaltyHalfH)
  line(PitchXMax, CentreY - PenaltyHalfH,
    WorldW - PenaltyDepth, CentreY - PenaltyHalfH)
  line(PitchXMax, CentreY + PenaltyHalfH,
    WorldW - PenaltyDepth, CentreY + PenaltyHalfH)
  # Goal arcs and the centre spot.
  ctx.fillStyle = LineColor
  ctx.fillEllipse(vec2(bx(CentreX), by(CentreY)), stroke, stroke)
  ctx.strokeEllipse(vec2(bx(PitchXMin + 3_000_000'i32), by(CentreY)),
    bx(1_600_000'i32), bx(1_600_000'i32))
  ctx.strokeEllipse(vec2(bx(PitchXMax - 3_000_000'i32), by(CentreY)),
    bx(1_600_000'i32), bx(1_600_000'i32))
  # Goalposts.
  for post in Posts:
    ctx.fillStyle = rgba(244, 246, 244, 255)
    ctx.fillEllipse(vec2(bx(post.x), by(post.y)), bx(PostRadius), bx(PostRadius))

proc invalidateBoardMapCaches*() =
  ## Drops every process-wide cache derived from the board bake. Needed when
  ## the serve loop hot-switches replays.
  pitchBands = @[]
  pitchBandRows = @[]

proc ensurePitchBands() =
  if pitchBands.len > 0:
    return
  let image = bakePitchImage()
  var y = 0
  while y < BoardH:
    let rows = min(MapBandRows, BoardH - y)
    var band = newSeq[uint8](BoardW * rows * 4)
    for row in 0 ..< rows:
      for x in 0 ..< BoardW:
        let
          c = image.data[(y + row) * BoardW + x].rgba()
          o = (row * BoardW + x) * 4
        band[o] = c.r
        band[o + 1] = c.g
        band[o + 2] = c.b
        band[o + 3] = c.a
    pitchBands.add(band)
    pitchBandRows.add(rows)
    y += rows
  doAssert pitchBands.len <= MaxMapBands, "pitch band pool overflow"

proc warmBoardRenderCaches*(sim: SimServer) =
  ## Pre-bakes every process-wide render cache at server startup so the first
  ## viewer's init packet is assembled instantly. Without this the first
  ## connection pays the whole bake, which trips the coworld certifier's
  ## first-message timeout. Idempotent.
  discard sim
  ensurePitchBands()
  for seat in Seat:
    for step in 0 ..< RigSteps:
      discard rigPixels(seat, step, 1)
  discard ballPixels(1)

# --------------------------------------------------------------------------
# Emission helpers
# --------------------------------------------------------------------------

proc addSpriteOnce(
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition],
  spriteId, width, height: int,
  pixels: seq[uint8],
  label: string
) =
  ## Emits a sprite definition only when this viewer has not already been sent
  ## an identical one. Sprite definitions are the expensive half of the wire.
  for existing in defs:
    if existing.spriteId == spriteId:
      if existing.width == width and existing.height == height and
          existing.label == label and existing.pixels == pixels:
        return
      existing.width = width
      existing.height = height
      existing.label = label
      existing.pixels = pixels
      packet.addSprite(spriteId, width, height, pixels, label)
      return
  defs.add SpriteDefinition(spriteId: spriteId, width: width, height: height,
    label: label, pixels: pixels)
  packet.addSprite(spriteId, width, height, pixels, label)

proc rigSpriteId(seat: Seat, step: int): int {.inline.} =
  RigSpriteBase + ord(seat) * RigSteps + step

proc trailTint(seat: int32): int {.inline.} =
  if seat < 0: 2 else: int(seat)

proc trailSpriteId(seat: int32, stage: int): int {.inline.} =
  TrailSpriteBase + trailTint(seat) * TrailStages + stage

proc trailColour(seat: int32, stage: int): ColorRGBA =
  let alpha = uint8(30 + stage * 22)
  case trailTint(seat)
  of 0: rgba(AzureColor.r, AzureColor.g, AzureColor.b, alpha)
  of 1: rgba(CrimsonColor.r, CrimsonColor.g, CrimsonColor.b, alpha)
  else: rgba(238, 238, 226, alpha)

proc addBoardChrome(
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition]
) =
  ## Viewport, layers and the banded turf. Emitted once per viewer.
  ensurePitchBands()
  packet.addViewport(MapLayerId, BoardW, BoardH)
  packet.addLayer(MapLayerId, 0, SpriteLayerZoomableFlag)
  var y = 0
  for i, band in pitchBands:
    packet.addSpriteOnce(defs, MapBandSpriteBase + i, BoardW, pitchBandRows[i],
      band, LabelPitch)
    packet.addObject(MapBandObjectBase + i, 0, y, -1000, MapLayerId,
      MapBandSpriteBase + i)
    y += pitchBandRows[i]

proc addBallAndRobots(
  sim: SimServer,
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition],
  selfSeat: int
) =
  const half = RigCanvas * BoardScale div 2
  for i in 0 ..< RobotCount:
    let
      robot = sim.robots[i]
      step = headingStep(robot.headingBrads())
      spriteId = rigSpriteId(seatOfRobot(i), step)
    packet.addSpriteOnce(defs, spriteId, RigCanvas * BoardScale,
      RigCanvas * BoardScale, rigPixels(seatOfRobot(i), step, BoardScale),
      LabelRobot & " " & robotId(i))
    packet.addObject(RobotObjectBase + i,
      worldToBoard(robot.x) - half, worldToBoard(robot.y) - half,
      100 + i, MapLayerId, spriteId)
  const ballHalf = BallSpritePx * BoardScale div 2
  packet.addSpriteOnce(defs, BallSpriteId, BallSpritePx * BoardScale,
    BallSpritePx * BoardScale, ballPixels(BoardScale), LabelBall)
  packet.addObject(BallObjectId,
    worldToBoard(sim.ball.x) - ballHalf, worldToBoard(sim.ball.y) - ballHalf,
    200, MapLayerId, BallSpriteId)
  if selfSeat >= 0:
    const markerPx = 10 * BoardScale
    packet.addSpriteOnce(defs, SelfMarkerSpriteId, markerPx, markerPx,
      discPixels(markerPx, rgba(255, 244, 190, 210)), LabelSelfMarker)
    for slot in 0 ..< RobotsPerSeat:
      let i = firstRobotOf(Seat(selfSeat and 1)) + slot
      packet.addObject(SelfMarkerObjectBase + slot,
        worldToBoard(sim.robots[i].x) - markerPx div 2,
        worldToBoard(sim.robots[i].y) - RigCanvas * BoardScale div 2 - markerPx,
        300, MapLayerId, SelfMarkerSpriteId)

proc addTrail(
  sim: SimServer,
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition]
) =
  ## The last 45 tick positions as a tapering ribbon, tinted by the last
  ## toucher's livery.
  let count = min(sim.trail.len, TrailSlots)
  for slot in 0 ..< TrailSlots:
    let index = sim.trail.len - count + slot
    if slot >= count:
      packet.addDeleteObject(TrailObjectBase + slot)
      continue
    let
      point = sim.trail[index]
      stage = slot * TrailStages div max(1, count)
      size = (3 + stage) * BoardScale
      spriteId = trailSpriteId(point.seat, stage)
    packet.addSpriteOnce(defs, spriteId, size, size,
      discPixels(size, trailColour(point.seat, stage)), LabelBallTrail)
    packet.addObject(TrailObjectBase + slot,
      worldToBoard(point.x) - size div 2, worldToBoard(point.y) - size div 2,
      150, MapLayerId, spriteId)

proc addPaint(
  sim: SimServer,
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition],
  sent: var int
) =
  ## Position-history tinting: each robot paints the turf it drives over,
  ## accumulating into the board. Append-only and emitted once each, so this
  ## costs nothing per frame once a viewer has caught up.
  const dot = 7 * BoardScale
  if sent > sim.paint.len:
    sent = 0                        ## a scrub back rewound the history.
  while sent < sim.paint.len:
    let
      point = sim.paint[sent]
      hue = RobotHues[int(point.robot) mod RobotCount]
      spriteId = PaintSpriteBase + int(point.robot) mod RobotCount
    packet.addSpriteOnce(defs, spriteId, dot, dot,
      discPixels(dot, hueColour(hue, 46)), LabelPaint)
    packet.addObject(PaintObjectBase + (sent mod PaintSlots),
      worldToBoard(point.x) - dot div 2, worldToBoard(point.y) - dot div 2,
      -500, MapLayerId, spriteId)
    inc sent

proc addKickFx(
  sim: SimServer,
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition]
) =
  ## An expanding ring at each recent kick's contact point, plus a one-frame
  ## white flash on the ball at the instant of contact.
  var slot = 0
  for fx in sim.kickFx:
    let age = sim.tickCount - int(fx.tick)
    if age < 0 or age >= KickFxTicks or slot >= KickSlots:
      continue
    let
      stage = age
      size = KickRingStartPx + (KickRingEndPx - KickRingStartPx) * stage div
        KickFxTicks
      alpha = uint8(max(0, 220 - stage * 18))
      base = if fx.seat == 0: AzureColor else: CrimsonColor
      spriteId = KickRingSpriteBase + stage
    packet.addSpriteOnce(defs, spriteId, size, size,
      ringPixels(size, rgba(base.r, base.g, base.b, alpha),
        float32(2 * BoardScale)), LabelKickFx)
    packet.addObject(KickObjectBase + slot,
      worldToBoard(fx.x) - size div 2, worldToBoard(fx.y) - size div 2,
      250, MapLayerId, spriteId)
    inc slot
  while slot < KickSlots:
    packet.addDeleteObject(KickObjectBase + slot)
    inc slot

proc addGoalFx(
  sim: SimServer,
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition]
) =
  ## Full-canvas flash plus 120 particles in the scoring livery for 45 frames.
  var active = -1
  var seat = 0
  for fx in sim.goalFx:
    let age = sim.tickCount - int(fx.tick)
    if age >= 0 and age < GoalFxTicks:
      active = age
      seat = int(fx.seat)
  if active < 0:
    packet.addDeleteObject(GoalFlashObjectId)
    for i in 0 ..< ConfettiSlots:
      packet.addDeleteObject(ConfettiObjectBase + i)
    return
  let
    flashAlpha = uint8(max(0, 170 - active * 8))
    tint = if seat == 0: AzureColor else: CrimsonColor
  packet.addSpriteOnce(defs, GoalFlashSpriteId, 8, 8,
    discPixels(8, rgba(255, 255, 255, flashAlpha), feather = false),
    LabelGoalFlash)
  packet.addObject(GoalFlashObjectId, 0, 0, 900, MapLayerId, GoalFlashSpriteId)
  const confettiPx = 5 * BoardScale
  packet.addSpriteOnce(defs, ConfettiSpriteBase + seat, confettiPx, confettiPx,
    discPixels(confettiPx, rgba(tint.r, tint.g, tint.b, 230)), LabelConfetti)
  for i in 0 ..< ConfettiSlots:
    # Deterministic scatter: derived from the particle index, so a replay
    # re-derives the identical celebration.
    let
      angle = float(i) * 2.399963
      radius = float(40 + (i * 37) mod 240) * float(active) / float(GoalFxTicks)
      cx = worldToBoard(CentreX) + int(cos(angle) * radius * float(BoardScale))
      cy = worldToBoard(CentreY) + int(sin(angle) * radius * float(BoardScale)) +
        active * 2
    packet.addObject(ConfettiObjectBase + i, cx, cy, 950, MapLayerId,
      ConfettiSpriteBase + seat)

# --------------------------------------------------------------------------
# The two builders
# --------------------------------------------------------------------------

proc buildBoard(
  sim: SimServer,
  defs: var seq[SpriteDefinition],
  initialized: var bool,
  paintSent: var int,
  selfSeat: int
): seq[uint8] =
  if not initialized:
    result.addBoardChrome(defs)
    initialized = true
  sim.addPaint(result, defs, paintSent)
  sim.addTrail(result, defs)
  sim.addBallAndRobots(result, defs, selfSeat)
  sim.addKickFx(result, defs)
  sim.addGoalFx(result, defs)

proc buildSpriteProtocolUpdates*(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  tick: int,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int
): seq[uint8] =
  ## The SPECTATOR / replay board. Perfect information: no fog, no vision cone,
  ## no first-person inset — soccer is a perfect-information sport.
  nextState = state
  result = buildBoard(sim, nextState.spriteDefs, nextState.initialized,
    nextState.paintSent, -1)
  discard tick
  discard playing
  discard speed
  discard maxTick
  discard looping
  discard transportEnabled
  discard mismatchTick

proc buildSpriteProtocolPlayerUpdates*(
  sim: var SimServer,
  playerIndex: int,
  state: PlayerViewerState,
  nextState: var PlayerViewerState,
  spritesOff = false
): seq[uint8] =
  ## One seat's stream. It sees the whole pitch and every body — plus a self
  ## marker on its own trio and an invisible `own seat <alias>` marker naming
  ## it. It never sees a real player name: board labels carry only `AZ-1`..
  ## `CR-3`, and `showPlayerLabels` is forced false on this path.
  nextState = state
  if nextState.isNil:
    nextState = initPlayerViewerState()
  let seat =
    if playerIndex >= 0 and playerIndex < sim.players.len:
      ord(sim.players[playerIndex].seat)
    else:
      -1
  result = buildBoard(sim, nextState.spriteDefs, nextState.initialized,
    nextState.paintSent, seat)
  if seat >= 0:
    result.addSpriteOnce(nextState.spriteDefs, OwnSeatSpriteId, 1, 1,
      @[0'u8, 0, 0, 0], LabelOwnSeat & " " & seatAlias(Seat(seat and 1)))
    result.addObject(OwnSeatObjectId, 0, 0, 999, MapLayerId, OwnSeatSpriteId)
  discard spritesOff
