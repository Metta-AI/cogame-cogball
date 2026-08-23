## The static WASM replay viewer's entry points. Kept from ctf's
## ctf's replay entry module, renamed: it imports the SAME `src/cogball/sim.nim` the
## native server ran, so `cogball_frame` re-steps the recorded masks through
## the identical physics core and `checkReplayHash` compares every tick.

import
  std/json,
  cogball/[broadcast, global, replay_runtime, replays, sim]

var
  runtimeLoaded = false
  replay: ReplayPlayer
  game: SimServer
  viewer: GlobalViewerState
  tracker: BroadcastTracker
  packet: seq[uint8]
  lastError: string

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with -s ABORTING_MALLOC=1 — allocation failure aborts the runtime loudly —
## and this fixed buffer, stamped BEFORE each risky phase, stays readable from
## JS after the abort (aborting kills the call stack, not linear memory), so
## the page can still report what the runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent(events: JsonNode) =
  var nextViewer: GlobalViewerState
  packet = game.buildReplayViewerPacket(replay, viewer, nextViewer, events)
  viewer = nextViewer

proc cogballLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "cogball_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let replayData = parseReplayBytes(data.bytesFromPointer(int(length)))
    stampStage("initialize replay runtime")
    # Match the native replay server default: keep a historical replay usable
    # after the first integrity mismatch and surface the warning in the shared
    # chrome. `--mismatch-quit` remains a native diagnostic mode.
    var initialized = initReplayRuntime(
      replayData,
      mismatchQuit = false,
      gameEventLoggingEnabled = false
    )
    game = move(initialized.sim)
    replay = move(initialized.player)
    tracker = move(initialized.tracker)
    viewer = initGlobalViewerState()
    runtimeLoaded = true
    frameStage = "advance replay"
    stampStage("render first frame")
    renderCurrent(newJArray())
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc cogballInput(data: ptr uint8, length: cint)
    {.exportc: "cogball_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc cogballFrame(): cint {.exportc: "cogball_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    let seekTicks =
      if viewer.replaySeekTick >= 0: @[viewer.replaySeekTick]
      else: newSeq[int]()
    let events = replay.advanceReplayFrame(
      game, tracker, seekTicks, viewer.replayCommands)
    viewer.replaySeekTick = -1
    viewer.replayCommands.setLen(0)
    renderCurrent(events)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc cogballPacketPointer(): ptr uint8 {.exportc: "cogball_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc cogballPacketLength(): cint {.exportc: "cogball_packet_len", cdecl.} =
  cint(packet.len)

proc cogballMismatchTick(): cint {.exportc: "cogball_mismatch_tick", cdecl.} =
  if runtimeLoaded: cint(replay.hashMismatchTick) else: -1

proc cogballErrorPointer(): ptr uint8 {.exportc: "cogball_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc cogballErrorLength(): cint {.exportc: "cogball_error_len", cdecl.} =
  cint(lastError.len)

proc cogballStagePointer(): ptr uint8 {.exportc: "cogball_stage_ptr", cdecl.} =
  ## The progress note. Unlike cogball_error_*, this stays valid after an
  ## allocation-failure abort, so JS can report what the runtime was doing.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc cogballStageLength(): cint {.exportc: "cogball_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing render caches, fonts — everything — while the wasm module stays
  # alive and JS keeps calling cogball_load_replay/cogball_frame. Unwinding
  # main through emscripten's live-runtime exit skips the destructor epilogue
  # entirely, so globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
