## The replay codec wrapper: keyframes, sim (de)serialization, the incremental
## whole-match scan, lull spans, beat events, seek/speed/transport commands and
## `checkReplayHash`. Kept from ctf's `replays.nim` with TWO named edits and the
## magic/name/version swap.
##
## **Edit 1 — masks are indexed by ROBOT, not by roster slot.**
## `replayPrevInputs`/`replayInputs` build `seq[InputState](RobotCount)` and
## `replayWriter.lastMasks` is sized to six. Joins and leaves still carry the
## two seats (names, tokens, rewards); the ACTION LOG is the six robots.
##
## **Edit 2 — a leave does not shift the mask arrays.**
## ctf deletes a leaving player's mask entries because its masks ARE its
## players. Cogball's robots are fixed for the whole match, so a leave removes
## the roster entry and leaves the six mask slots alone. Keeping ctf's
## delete-on-leave here would renumber robots mid-replay — exactly the bug
## class that rule exists to avoid, in the game shape where it applies.

import
  std/json,
  flatty,
  bitworld/spriteprotocol,
  bitworld/replays as replayCodec,
  broadcast, sim, roster

type
  ReplayKeyframe* = object
    tick*: int
    simBytes*: string
    joinIndex*: int
    leaveIndex*: int
    chatIndex*: int
    inputIndex*: int
    hashIndex*: int
    masks*: seq[uint8]
    lastAppliedMasks*: seq[uint8]
    hashValidationFailed*: bool
    hashMismatchTick*: int

  ReplayPlayer* = object
    data*: ReplayData
    joinIndex*: int
    leaveIndex*: int
    chatIndex*: int
    inputIndex*: int
    hashIndex*: int
    masks*: seq[uint8]
    lastAppliedMasks*: seq[uint8]
    playing*: bool
    looping*: bool
    speedIndex*: int
      ## Index into PlaybackSpeeds, or ReplayHalfSpeedIndex (-1) for the
      ## replay-only 1/2x speed (one sim tick every other frame).
    halfPhase*: bool
      ## Frame parity while at 1/2x speed: ticks advance only on the odd
      ## frames, toggled once per advanceReplayPlayback frame.
    mismatchQuit*: bool
    hashValidationFailed*: bool
    hashMismatchTick*: int
    keyframes*: seq[ReplayKeyframe]
    startTick*: int
      ## First tick the match is actually being PLAYED. Playback auto-starts
      ## here, loops back here, and the scrubber is offset by it.
    leadSeries*: seq[seq[int]]
      ## [tick, goalsPerSeat...] change-points across the WHOLE match, so the
      ## momentum graph draws its full shape at once.
    endHoldFrames*: int
    skipLulls*: bool
    lullSpans*: seq[array[2, int]]
    beatEvents*: JsonNode
    scan: ReplayScan
    scanDone: bool

  ReplayScan* = ref object
    sim: SimServer
    builder: ReplayPlayer
    beatTracker: BroadcastTracker
    beatTicks: seq[int]
    lastGoals: seq[int]
    interval: int
    maxTick: int

export PlaybackSpeeds

const
  ReplayHalfSpeedIndex* = -1
    ## speedIndex sentinel for 1/2x playback: one sim tick every other frame.
    ## Replay-only — the live loop clamps it back to PlaybackSpeeds[0] (1x).
  ReplayKeyframeTicks* = 100
  ReplayEndHoldSeconds* = 10
  LullLeadTicks* = 2 * ReplayFps
  MinLullTicks* = 6 * ReplayFps
  LullSpeedBoost* = 8
  MaxLullTicksPerFrame* = 64
  CogballReplayMagic* = "COWLDBAL"
  CogballReplayFormatVersion = 1'u16
  CogballReplaySpec = ReplaySpec(
    magic: CogballReplayMagic,
    formatVersion: CogballReplayFormatVersion,
    gameName: GameName,
    gameVersion: GameVersion,
    joinKind: rjkNameSlotToken,
    allowChat: true,
    allowCompressed: true,
    hashOrder: rhoStop
  )

export replayCodec

proc tickTime*(tick: int): uint32 =
  replayCodec.tickTime(tick, ReplayFps)

proc openReplayWriter*(path: string, configJson: string): ReplayWriter =
  replayCodec.openReplayWriter(path, configJson, CogballReplaySpec)

proc writeInputMaskChange*(
  replayWriter: var ReplayWriter,
  time: uint32,
  robotIndex: int,
  mask: uint8
) =
  ## Writes one replay input record when a ROBOT's applied mask changes.
  ## EDIT 1 again, on the writing side: the `player` byte of an input record is
  ## a ROBOT index 0..5, not a roster slot.
  if robotIndex < 0 or robotIndex >= replayWriter.lastMasks.len:
    return
  if replayWriter.lastMasks[robotIndex] == mask:
    return
  replayWriter.writeInput(ReplayInput(
    time: time, player: uint8(robotIndex), keys: mask))
  replayWriter.lastMasks[robotIndex] = mask

proc writeInputFrameMasks*(
  replayWriter: var ReplayWriter,
  time: uint32,
  masks: array[RobotCount, uint8]
) =
  ## The determinism boundary: the six masks that were actually stepped.
  for i in 0 ..< RobotCount:
    replayWriter.writeInputMaskChange(time, i, masks[i])

proc parseReplayBytes*(bytes: string): ReplayData =
  replayCodec.parseReplayBytes(bytes, CogballReplaySpec)

proc loadReplay*(path: string): ReplayData =
  replayCodec.loadReplay(path, CogballReplaySpec)

proc serializeReplaySim*(sim: var SimServer): string =
  ## Serializes one sim state for a keyframe. The board bake is process-wide
  ## (global.nim owns it), so unlike ctf there is no baked-pixel field to strip
  ## out of the keyframe before writing it -- and no field is carried for one.
  sim.toFlatty()

proc deserializeReplaySim*(bytes: string, donor: var SimServer): SimServer =
  discard donor
  bytes.fromFlatty(SimServer)

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  result.data = data
  result.masks = newSeq[uint8](RobotCount)
  result.lastAppliedMasks = newSeq[uint8](RobotCount)
  result.playing = true
  result.looping = true
  result.speedIndex = 0
  result.skipLulls = true
  result.hashMismatchTick = -1

proc replaySpeed*(replay: ReplayPlayer): int =
  ## Returns the current integer replay speed (1 while at 1/2x — the
  ## fractional pace lives in replayStepBudget's frame parity).
  PlaybackSpeeds[clamp(replay.speedIndex, 0, PlaybackSpeeds.high)]

proc replayDisplaySpeed*(replay: ReplayPlayer): float =
  ## Returns the speed the chrome shows: 0.5 at half speed, else the
  ## integer speed.
  if replay.speedIndex == ReplayHalfSpeedIndex: 0.5
  else: float(replay.replaySpeed())

proc replayMaxTick*(replay: ReplayPlayer): int =
  if replay.data.hashes.len == 0:
    return 0
  int(replay.data.hashes[^1].tick)

proc replayStartTick*(replay: ReplayPlayer): int =
  clamp(max(0, replay.startTick), 0, replay.replayMaxTick())

proc resetReplay*(replay: var ReplayPlayer) =
  replay.joinIndex = 0
  replay.leaveIndex = 0
  replay.chatIndex = 0
  replay.inputIndex = 0
  replay.hashIndex = 0
  replay.hashValidationFailed = false
  replay.hashMismatchTick = -1
  replay.masks = newSeq[uint8](RobotCount)
  replay.lastAppliedMasks = newSeq[uint8](RobotCount)

proc saveReplayKeyframe(
  replay: ReplayPlayer,
  sim: var SimServer
): ReplayKeyframe =
  ReplayKeyframe(
    tick: sim.tickCount,
    simBytes: serializeReplaySim(sim),
    joinIndex: replay.joinIndex,
    leaveIndex: replay.leaveIndex,
    chatIndex: replay.chatIndex,
    inputIndex: replay.inputIndex,
    hashIndex: replay.hashIndex,
    masks: replay.masks,
    lastAppliedMasks: replay.lastAppliedMasks,
    hashValidationFailed: replay.hashValidationFailed,
    hashMismatchTick: replay.hashMismatchTick
  )

proc restoreReplayKeyframe(
  replay: var ReplayPlayer,
  sim: var SimServer,
  keyframe: ReplayKeyframe
) =
  let gameEventLoggingEnabled = sim.gameEventLoggingEnabled
  var restored = deserializeReplaySim(keyframe.simBytes, sim)
  restored.gameEventLoggingEnabled = gameEventLoggingEnabled
  sim = move(restored)
  replay.joinIndex = keyframe.joinIndex
  replay.leaveIndex = keyframe.leaveIndex
  replay.chatIndex = keyframe.chatIndex
  replay.inputIndex = keyframe.inputIndex
  replay.hashIndex = keyframe.hashIndex
  replay.masks = keyframe.masks
  replay.lastAppliedMasks = keyframe.lastAppliedMasks
  replay.hashValidationFailed = keyframe.hashValidationFailed
  replay.hashMismatchTick = keyframe.hashMismatchTick

proc replayKeyframeIndex(replay: ReplayPlayer, tick: int): int =
  for i, keyframe in replay.keyframes:
    if keyframe.tick > tick:
      break
    result = i

proc applyReplayEvents(replay: var ReplayPlayer, sim: var SimServer) =
  ## Applies replay joins, leaves, inputs and chat records for the current
  ## tick. EDIT 2: a leave removes the roster entry and leaves the six mask
  ## slots alone.
  let time = tickTime(sim.tickCount)
  while replay.leaveIndex < replay.data.leaves.len and
      replay.data.leaves[replay.leaveIndex].time <= time:
    let leave = replay.data.leaves[replay.leaveIndex]
    if int(leave.player) < 0 or int(leave.player) >= sim.players.len:
      raise newException(ReplayError, "Replay player leave is invalid")
    sim.removePlayerAt(int(leave.player))
    inc replay.leaveIndex

  while replay.joinIndex < replay.data.joins.len and
      replay.data.joins[replay.joinIndex].time <= time:
    let join = replay.data.joins[replay.joinIndex]
    if int(join.player) != sim.players.len:
      raise newException(ReplayError, "Replay player join order is invalid")
    discard sim.addPlayer(join.name, join.slot, join.token, trusted = true)
    inc replay.joinIndex

  while replay.inputIndex < replay.data.inputs.len and
      replay.data.inputs[replay.inputIndex].time <= time:
    let input = replay.data.inputs[replay.inputIndex]
    if int(input.player) < RobotCount:
      replay.masks[int(input.player)] = input.keys
    inc replay.inputIndex

  while replay.chatIndex < replay.data.chats.len and
      replay.data.chats[replay.chatIndex].time <= time:
    sim.applyRecord(replay.data.chats[replay.chatIndex].message)
    inc replay.chatIndex

proc replayPrevInputs(replay: var ReplayPlayer): seq[InputState] =
  ## EDIT 1: sized to the SIX ROBOTS, never to the roster.
  result = newSeq[InputState](RobotCount)
  for i in 0 ..< RobotCount:
    result[i] = decodeInputMask(replay.lastAppliedMasks[i])

proc replayInputs(replay: var ReplayPlayer): seq[InputState] =
  result = newSeq[InputState](RobotCount)
  for i in 0 ..< RobotCount:
    result[i] = decodeInputMask(replay.masks[i])
    replay.lastAppliedMasks[i] = replay.masks[i]

proc checkReplayHash(replay: var ReplayPlayer, sim: SimServer) =
  ## The integrity chain. A single divergent bit is caught at the tick it
  ## happens and surfaced as `mismatchTick`.
  if replay.hashValidationFailed:
    if sim.tickCount >= replay.replayMaxTick():
      replay.playing = false
    return
  if replay.hashIndex >= replay.data.hashes.len:
    replay.playing = false
    return
  let expected = replay.data.hashes[replay.hashIndex]
  if int(expected.tick) < sim.tickCount:
    let message = "Replay hash tick is missing at tick " & $sim.tickCount & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  if int(expected.tick) > sim.tickCount:
    return
  let hash = sim.gameHash()
  if hash != expected.hash:
    let message = "Replay hash mismatch at tick " & $sim.tickCount &
      "; expected " & $expected.hash & ", got " & $hash & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  inc replay.hashIndex

proc stepReplay*(replay: var ReplayPlayer, sim: var SimServer) =
  replay.applyReplayEvents(sim)
  let prevInputs = replay.replayPrevInputs()
  let inputs = replay.replayInputs()
  sim.step(inputs, prevInputs)
  replay.checkReplayHash(sim)

proc buildLullSpans*(
  beatTicks: seq[int],
  startTick, maxTick: int
): seq[array[2, int]] =
  ## Turns the ascending beat-tick list into the quiet spans between beats,
  ## keeping LullLeadTicks of context on both sides.
  var prevBeat = startTick
  for i in 0 .. beatTicks.len:
    let nextBeat =
      if i < beatTicks.len: beatTicks[i]
      else: maxTick + LullLeadTicks + 1
    let
      a = prevBeat + LullLeadTicks + 1
      b = min(nextBeat - LullLeadTicks - 1, maxTick)
    if b - a + 1 >= MinLullTicks:
      result.add([a, b])
    if i < beatTicks.len:
      prevBeat = nextBeat

proc scanTeamGoals(sim: SimServer): seq[int] =
  for seat in Seat:
    result.add(sim.goals(seat))

proc scanSeriesPoint(tick: int, goals: seq[int]): seq[int] =
  result = @[tick]
  result.add(goals)

proc scanComplete*(replay: ReplayPlayer): bool =
  replay.scanDone

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int)

proc initReplayScan*(
  replay: var ReplayPlayer,
  initialSim: SimServer,
  interval = ReplayKeyframeTicks
) =
  ## Starts the whole-match precompute walk: seek keyframes, the goal-difference
  ## change-point series, the story beats, and the beat ticks the lull map
  ## derives from.
  replay.keyframes = @[]
  replay.leadSeries = @[]
  replay.lullSpans = @[]
  replay.beatEvents = newJArray()
  replay.scanDone = false
  var scan = ReplayScan(interval: max(interval, 1))
  scan.sim = initialSim
  scan.sim.gameEventLoggingEnabled = false
  scan.builder = initReplayPlayer(replay.data)
  scan.builder.looping = false
  scan.builder.mismatchQuit = replay.mismatchQuit
  scan.maxTick = scan.builder.replayMaxTick()
  replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim))
  scan.lastGoals = scanTeamGoals(scan.sim)
  replay.leadSeries.add(scanSeriesPoint(scan.sim.tickCount, scan.lastGoals))
  scan.beatTracker = initBroadcastTracker()
  scan.beatTracker.resync(scan.sim)
  replay.startTick =
    if scan.sim.phase == Playing: scan.sim.gameStartTick else: -1
  replay.scan = scan
  replay.advanceReplayScan(0)

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int) =
  ## Advances the precompute walk by up to `maxTicks` sim ticks; when it stops
  ## it derives the lull spans and marks the lead chrome ready.
  if replay.scan == nil:
    return
  let scan = replay.scan
  var stepsLeft = maxTicks
  while stepsLeft > 0 and scan.builder.playing and
      scan.sim.tickCount < scan.maxTick:
    try:
      scan.builder.stepReplay(scan.sim)
    except ReplayError as error:
      if replay.mismatchQuit:
        raise
      echo "replay scan stopped at tick ", scan.sim.tickCount, ": ", error.msg
      scan.builder.playing = false
      break
    if replay.startTick < 0 and scan.sim.phase == Playing:
      replay.startTick = scan.sim.gameStartTick
    let goals = scanTeamGoals(scan.sim)
    if goals != scan.lastGoals:
      replay.leadSeries.add(scanSeriesPoint(scan.sim.tickCount, goals))
      scan.lastGoals = goals
    var stepBeats = newJArray()
    scan.sim.stepEvents(scan.beatTracker, stepBeats)
    for event in stepBeats:
      if event["k"].getStr() in ["goal", "drop", "gameover"]:
        replay.beatEvents.add(event)
    for event in stepBeats:
      if event["k"].getStr() in ["goal", "drop", "save", "shot", "gameover"]:
        scan.beatTicks.add(scan.sim.tickCount)
        break
    if scan.sim.tickCount mod scan.interval == 0 or
        scan.sim.tickCount == scan.maxTick:
      replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim))
    dec stepsLeft
  if scan.builder.playing and scan.sim.tickCount < scan.maxTick:
    return
  if replay.leadSeries.len == 0 or
      replay.leadSeries[^1][0] != scan.sim.tickCount:
    replay.leadSeries.add(scanSeriesPoint(scan.sim.tickCount, scan.lastGoals))
  replay.lullSpans = buildLullSpans(
    scan.beatTicks, replay.replayStartTick(), scan.maxTick)
  replay.scan = nil
  replay.scanDone = true

proc replayScanTicksPerFrame*(sim: SimServer): int =
  ## Deterministic scan slice per presentation frame (frame-counted, no clock
  ## reads — machine speed must not change what any frame contains).
  discard sim
  96

proc buildReplayKeyframes*(
  replay: var ReplayPlayer,
  initialSim: SimServer,
  interval = ReplayKeyframeTicks
) =
  replay.initReplayScan(initialSim, interval)
  replay.advanceReplayScan(int.high)

proc isLullTick*(replay: ReplayPlayer, tick: int): bool =
  for span in replay.lullSpans:
    if tick < span[0]:
      return false
    if tick <= span[1]:
      return true
  false

proc replayStepBudget*(replay: ReplayPlayer, tick: int): int =
  ## Returns how many ticks playback may advance this frame from one tick:
  ## the chosen speed, boosted inside a lull while skip-lulls is on. At 1/2x
  ## a tick is spent only every other frame (halfPhase parity).
  let speed = replay.replaySpeed()
  if replay.skipLulls and replay.isLullTick(tick):
    return min(speed * LullSpeedBoost, MaxLullTicksPerFrame)
  if replay.speedIndex == ReplayHalfSpeedIndex:
    return (if replay.halfPhase: 1 else: 0)
  speed

proc seekReplay*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(
      sim, replay.keyframes[replay.replayKeyframeIndex(tick)])
  else:
    let gameEventLoggingEnabled = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = gameEventLoggingEnabled
    replay.resetReplay()
  while sim.tickCount < tick and replay.hashIndex < replay.data.hashes.len:
    replay.stepReplay(sim)

proc applyReplaySeek*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  replay.playing = false
  replay.seekReplay(sim,
    clamp(tick, replay.replayStartTick(), replay.replayMaxTick()))

proc applySpeedCommand*(speedIndex: var int, command: char) =
  ## Applies one playback speed command. '5' selects the 1/2x replay speed
  ## (ReplayHalfSpeedIndex); the live loop clamps that back to 1x.
  case command
  of '+', '=': speedIndex = min(speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_': speedIndex = max(speedIndex - 1, ReplayHalfSpeedIndex)
  of '5': speedIndex = ReplayHalfSpeedIndex
  of '1': speedIndex = 0
  of '2': speedIndex = 1
  of '3': speedIndex = 2
  of '4': speedIndex = 3
  of '8': speedIndex = 4
  of '6': speedIndex = 5
  else: discard

proc applyReplayCommand*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  command: char
) =
  case command
  of ' ':
    replay.playing = not replay.playing
  of 'p':
    replay.playing = true
  of 'P':
    replay.playing = false
  of '+', '=', '-', '_', '1', '2', '3', '4', '5', '8', '6':
    applySpeedCommand(replay.speedIndex, command)
  of ',', '<':
    replay.playing = false
    replay.seekReplay(sim, replay.replayStartTick())
  of 'b':
    replay.playing = false
    replay.seekReplay(sim, max(replay.replayStartTick(), sim.tickCount - 1))
  of 'e':
    replay.playing = false
    replay.seekReplay(sim, replay.replayMaxTick())
  of 'r':
    replay.looping = not replay.looping
  of 'f':
    replay.skipLulls = not replay.skipLulls
  of '.', '>':
    replay.playing = false
    replay.seekReplay(sim, sim.tickCount + ReplayFps * 5)
  else:
    discard

proc cancelEndHold*(replay: var ReplayPlayer) =
  replay.endHoldFrames = 0

proc endHoldSecondsLeft*(replay: ReplayPlayer): int =
  if replay.endHoldFrames <= 0: 0
  else: (replay.endHoldFrames + ReplayFps - 1) div ReplayFps

proc advanceReplayPlayback*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  onStep: proc () {.closure.},
  onJump: proc () {.closure.}
) =
  ## Advances one real-time playback frame. A LOOPING replay does not restart
  ## the moment playback stops: the final game-over frame holds for
  ## ReplayEndHoldSeconds first.
  replay.halfPhase = not replay.halfPhase
  replay.advanceReplayScan(sim.replayScanTicksPerFrame())
  if replay.playing and replay.endHoldFrames > 0:
    replay.endHoldFrames = 0
    replay.seekReplay(sim, replay.replayStartTick())
    onJump()
  if replay.playing:
    replay.endHoldFrames = 0
    var stepsTaken = 0
    while replay.playing and
        stepsTaken < replay.replayStepBudget(sim.tickCount):
      replay.stepReplay(sim)
      onStep()
      inc stepsTaken
    if replay.looping and not replay.playing:
      replay.endHoldFrames = ReplayEndHoldSeconds * ReplayFps
  elif replay.endHoldFrames > 0:
    dec replay.endHoldFrames
    if replay.endHoldFrames == 0 and replay.looping:
      replay.seekReplay(sim, replay.replayStartTick())
      replay.playing = true
      onJump()

proc playbackSpeed*(speedIndex: int): int =
  PlaybackSpeeds[clamp(speedIndex, 0, PlaybackSpeeds.high)]
