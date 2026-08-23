## Viewer smoke, no browser: a static assertion over the chrome that the
## controls, the readouts, the density system and the wire constants are all
## present and cogball's.
##
## The RUNTIME half is the CI `wasm-viewer` job: the bundle builds, contains a
## non-empty `.wasm`, and `tools/wasm_replay_smoke.cjs` loads a fixture and
## advances 300 frames with no mismatch and no abort.

import std/[os, strutils]
import lib/helpers
import cogball/[global, labels, wire_constants]

let broadcastHtml = readFile("client/replay_broadcast.html")
let chromeCommon = readFile("client/chrome_common.js")
let broadcastCore = readFile("client/broadcast_core.js")
let leagueHtml = readFile("client/league_replayer.html")

proc must(text, needle, what: string) =
  doAssert text.contains(needle), what & " is missing: " & needle

proc transportAndReadouts() =
  for id in ["#scorebug", "#bannerlane", "#killfeed", "#endcard", "#mmwarn",
             "#transport", ".scrub", ".momentum", "#minimap", "#zoombar",
             "#stage", "#board", ".clock"]:
    must(broadcastHtml, id, "the broadcast chrome")
  for id in ["momentum", "lulls", "clock", "scrub"]:
    must(broadcastHtml, "id=\"" & id & "\"", "a chrome element")
  for id in ["btn-restart", "btn-back", "btn-play", "btn-fwd", "btn-end",
             "btn-loop", "btn-skip", "speedchips", "scrub-fill", "scrub-head",
             "tick-clock", "clock-time", "clock-caption", "scrub-win",
             "win-chip", "ffwd-chip"]:
    must(broadcastHtml, "id=\"" & id & "\"", "a transport control")
  report "every transport control and readout is present"

proc densitySystem() =
  ## The 360 px embed floor: the --hudscale clamp and the .tiny block are what
  ## keep the scorebug legible, and cogball adds two rules of its own.
  must(broadcastHtml, "--hudscale", "the density system")
  must(broadcastHtml, "Math.max(0.5, Math.min(1.6, boardW / 760))",
    "the --hudscale clamp")
  must(broadcastHtml, "stage.classList.toggle('tiny', boardW <= 640)",
    "the .tiny toggle")
  must(broadcastHtml, "#stage.tiny", "the .tiny CSS block")
  must(broadcastHtml, ".plate-name { flex: 1 1 auto; min-width: 3.2em;",
    "the plate-name rule")
  must(broadcastHtml, "#stage.tiny .plate .stat { display: none; }",
    "the tiny-mode stat hiding")
  must(broadcastHtml, "class=\"team-name plate-name\"",
    "the plate name class")
  report "the 360 px floor: --hudscale, .tiny, and the plate-name rule"

proc goalReplay() =
  ## The instant slow-mo goal replay is built purely out of the existing
  ## seek/speed commands, one replay per goal, cancellable by a manual scrub.
  must(broadcastHtml, "GOAL_REPLAY_BACK", "the slow-mo goal replay")
  must(broadcastHtml, "goalReplaySeen", "the once-per-goal guard")
  must(broadcastHtml, "cancelGoalReplay", "the scrub cancellation")
  must(broadcastHtml, "#stage.goal-replay::after", "the goal-replay vignette")
  must(broadcastHtml, "runGoalReplay(e.t, s)", "the goal beat trigger")
  report "the instant slow-mo goal replay is wired to the goal beat"

proc cogballFieldMapping() =
  ## The chrome reads cogball's fields, not paintbot's.
  must(chromeCommon, "var TEAM_ORDER = ['azure', 'crimson'];", "the team list")
  must(chromeCommon, "window.COGBALL_WIRE", "the wire constants hook")
  must(broadcastCore, "window.COGBALL_WIRE", "the core's wire constants hook")
  must(broadcastHtml, "tr[team].goals", "the scorebug goal numeral")
  must(broadcastHtml, "poss-", "the possession readout")
  must(broadcastHtml, "shots-", "the shots readout")
  must(chromeCommon, "(tr[team] && tr[team].goals) || 0",
    "the momentum series on goals")
  must(chromeCommon, "b.k === 'goal'", "the goal beat marker")
  must(chromeCommon, "b.k === 'drop'", "the drop beat marker")
  report "the chrome's field mapping is cogball's: goals, possession, shots"

proc noPaintbotIdentifiersSurvive() =
  ## No `ctf_` / `CTF_` identifier survives anywhere in client/, replay-viewer/
  ## or src/ — the mechanical rename sweep, asserted.
  var offenders: seq[string] = @[]
  for dir in ["client", "replay-viewer", "src"]:
    for path in walkDirRec(dir):
      if path.endsWith(".png") or path.endsWith(".jpg") or
         path.endsWith(".webp") or path.endsWith(".ttf"):
        continue
      let text = readFile(path)
      for ident in identifiers(text):
        if ident.startsWith("ctf_") or ident.startsWith("CTF_") or
            ident == "CtfStaticReplay":
          offenders.add(path & ": " & ident)
  doAssert offenders.len == 0,
    "paintbot identifiers survived:\n  " & offenders.join("\n  ")
  report "no ctf_/CTF_ identifier survives in client/, replay-viewer/ or src/"

proc coreIsVerbatimApartFromTheWireName() =
  ## broadcast_core.js is game-agnostic and kept verbatim apart from the one
  ## wire-constants identifier. Assert the shape rather than a byte diff: the
  ## starter is not vendored here.
  must(broadcastCore, "window.BroadcastCore = { create: BroadcastCore };",
    "the core's export")
  must(broadcastCore, "function BroadcastCore(config)", "the core entry point")
  doAssert not broadcastCore.contains("cogball"),
    "broadcast_core.js grew a game-specific reference; it must stay generic"
  var wireLines = 0
  for line in broadcastCore.splitLines():
    if line.contains("COGBALL_WIRE"):
      inc wireLines
  doAssert wireLines == 1,
    "broadcast_core.js should differ from the starter in exactly one " &
      "identifier, on one line; saw " & $wireLines & " lines"
  report "broadcast_core.js is generic apart from the one wire identifier"

proc wireConstants() =
  ## The engine renders the block; the clients read it. A retuned
  ## PlaybackSpeeds must never silently desync a client.
  doAssert WireConstantsJs.startsWith("window.COGBALL_WIRE={")
  must(WireConstantsJs, "speeds:[1,2,3,4,8,16]", "the speed table")
  must(WireConstantsJs, "fps:24", "the frame rate")
  must(WireConstantsJs, "chromeSpriteId:" & $BroadcastChromeSpriteId,
    "the chrome sprite id")
  must(WireConstantsJs, "turnTicks:120", "the coaching cadence")
  doAssert WireConstantsJs.endsWith("};")
  # The splice marker must exist in both pages, exactly once.
  doAssert broadcastHtml.count(WireConstantsMarker) == 1
  doAssert leagueHtml.count(WireConstantsMarker) == 1
  doAssert broadcastHtml.count("<!-- CHROME_COMMON -->") == 1
  doAssert broadcastHtml.count("<!-- BROADCAST_CORE -->") == 1
  let spliced = spliceWireConstants(broadcastHtml)
  doAssert spliced.contains("window.COGBALL_WIRE={")
  doAssert not spliced.contains(WireConstantsMarker)
  report "wire_constants renders window.COGBALL_WIRE and both pages splice it"

proc labelVocabulary() =
  ## The renderer emits nothing outside the contract vocabulary.
  var sim = playing(testConfig())
  sim.stepIdle(40)
  sim.kickFx.add KickFx(x: CentreX, y: CentreY, tick: int32(sim.tickCount),
    seat: 0)
  sim.goalFx.add GoalFx(tick: int32(sim.tickCount), seat: 1)
  var globalState = initGlobalViewerState()
  var nextGlobal: GlobalViewerState
  let board = sim.buildSpriteProtocolUpdates(
    globalState, nextGlobal, sim.tickCount, true, 1, 4800, true, true, -1)
  var playerState = initPlayerViewerState()
  var nextPlayer: PlayerViewerState
  let seatPacket = sim.buildSpriteProtocolPlayerUpdates(0, playerState,
    nextPlayer)
  var seen: seq[string]
  for packet in [board, seatPacket]:
    for message in packet.parseSpritePacket():
      if message.kind != spkSprite:
        continue
      var head = message.sprite.label
      let space = head.find(' ')
      if space > 0 and head.startsWith("robot"):
        head = head[0 ..< space]
      if head.startsWith("own seat"):
        head = LabelOwnSeat
      if head notin seen:
        seen.add(head)
  doAssert seen.len > 0
  for label in seen:
    var known = false
    for contract in ContractLabels:
      if label == contract:
        known = true
    doAssert known, "the renderer emitted an unlisted label: `" & label & "`"
  for required in [LabelPitch, LabelBall, LabelRobot]:
    doAssert required in seen, "the board never emitted `" & required & "`"
  report "every emitted sprite label is in the contract vocabulary"

proc boardGeometry() =
  ## The board aspect the chrome derives from the stream is the pitch's.
  doAssert BoardW == MapWidth * BoardScale
  doAssert BoardH == MapHeight * BoardScale
  doAssert MapWidth * MapScale == int(WorldW)
  doAssert MapHeight * MapScale == int(WorldH)
  must(broadcastHtml, "var BOARD_W = 1100, BOARD_H = 625;",
    "the board aspect fallback")
  report "the board is 1100:625, matching the 44 x 25 m world"

proc staticBundleAdapters() =
  let staticReplay = readFile("replay-viewer/static_replay.js")
  let worker = readFile("replay-viewer/static_replay_worker.js")
  must(staticReplay, "window.CogballStaticReplay", "the static bundle adapter")
  must(staticReplay, "static_replay_worker.js", "the worker reference")
  for symbol in ["_cogball_load_replay", "_cogball_frame", "_cogball_input",
                 "_cogball_packet_ptr", "_cogball_packet_len",
                 "_cogball_mismatch_tick", "_cogball_error_ptr",
                 "_cogball_stage_ptr"]:
    must(worker, symbol, "the worker's wasm binding")
  must(worker, "cogball_replay.js", "the wasm module")
  let config = readFile("replay-viewer/config.nims")
  for flag in ["ABORTING_MALLOC=1", "ALLOW_MEMORY_GROWTH",
               "ENVIRONMENT=web,worker,node", "--cpu:wasm32"]:
    must(config, flag, "an emscripten link flag")
  let smoke = readFile("tools/wasm_replay_smoke.cjs")
  must(smoke, "_cogball_mismatch_tick", "the determinism gate")
  report "the static bundle adapters and emscripten flags are cogball's"

when isMainModule:
  echo "test_viewer"
  transportAndReadouts()
  densitySystem()
  goalReplay()
  cogballFieldMapping()
  noPaintbotIdentifiersSurvive()
  coreIsVerbatimApartFromTheWireName()
  wireConstants()
  labelVocabulary()
  boardGeometry()
  staticBundleAdapters()
  echo "test_viewer: all good"
