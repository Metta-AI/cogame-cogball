## The episode server: the mummy HTTP/websocket server, `/healthz`,
## `/player?slot&token`, `/global`, `/replay`, `/client/*`, `/replay-data`,
## join/auth, the frame limiter, the replay-switch path, the `COGAME_*` runtime
## contract, `declarePlayerFailure` and the artifact-write block.
##
## This is ctf's `server.nim` with the named Cogball edits:
##
## 1. **Input source.** Where ctf reads `appState.inputMasks` (the socket) into
##    `inputs[playerIndex]`, cogball calls `control.compileMasks(sim,
##    directives)` and fills `inputs[robotIndex]` for the six robots. Player
##    sockets no longer contribute input.
## 2. **Turn boundary.** Immediately before stepping a tick where
##    `tick mod turnTicks == 0`, the loop runs `decide.turn`, which issues the
##    one parallel batch, applies the deadlines, installs the directives and
##    writes the directive/fallback records — all inside a monotonic
##    `turnBudgetMs` bound.
## 3. **Registration interception.** A player's Sprite v1 chat message whose
##    text parses as a registration object is consumed as registration and is
##    NOT written to the replay chat stream: the server writes a redacted
##    `register` record instead (policy label and kind, never the prompt). Any
##    other chat text from a player is dropped.
## 4. **Wall-clock stop.** A `wallClockBudgetSeconds` check at the top of every
##    loop iteration forces `phase = GameOver`, `reason = deadline`,
##    `endRule = wall_clock`.
## 5. **Player decision exchange.** The game sends private turns to player
##    sockets, waits for both replies in one bounded batch, and retains
##    validation, fallback and replay ownership.
##
## The whole loop is wrapped so an unexpected exception becomes
## `fault/host_error` with best-effort artifacts written before it is re-raised
## (docs/RULES.md "End conditions"): the runner gets a results.json and a
## partial replay instead of an unattributable episode.

import
  std/[json, locks, monotimes, nativesockets, options, os, sets, strutils, sysrand, tables, times],
  bitworld/client as bitworldClient,
  bitworld/[runtime, decision_trajectory, native_stop, artifact_runtime],
  bitworld/spriteprotocol,
  mummy,
  sim, roster, control, directives, decide,
  global, broadcast, replays, replay_runtime, events, wire_constants, training_capture, native_exchange

when defined(posix):
  from std/posix import SHUT_RDWR, shutdown

type
  WebSocketSocketFields = object
    server: Server
    clientSocket: SocketHandle
    clientId: uint64

  PrivatePlayerMessage = object
    data: string
    receivedAt: MonoTime

  WebSocketAppState = object
    lock: Lock
    replayServerMode: bool
    replayLoaded: bool
    started, stopping, sealed: bool
    authenticatedPlayers: Table[WebSocket, int]
    pendingReplayUri: string
    loadingReplayUri: string
    currentReplayUri: string
    chatMessages: Table[WebSocket, string]
    actionMessages: Table[WebSocket, seq[PrivatePlayerMessage]]
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    playerReady: Table[WebSocket, bool]
    globalViewers: Table[WebSocket, GlobalViewerState]
    playerViewers: Table[WebSocket, PlayerViewerState]
    closedSockets: seq[WebSocket]
    nextAnonymousPlayer: int
    config: GameConfig

  GameThreadArgs = object
    server: ptr Server
    initialConfig: GameConfig
    saveReplayPath, loadReplayPath, saveScoresPath: string
    runtimeConfig: RuntimeConfig
    episodeStart: MonoTime

const
  HealthPath = "/healthz"
  ReplayDataPath = "/replay-data"
  BroadcastFontPath = "/client/font.ttf"
  LeagueReplayerPath = "/client/league"
  MaxWsFrameBytes* = 900_000
    ## Hosted replay closes any WS frame larger than 1 MiB (1009). Chunk under
    ## a margin below that so no single frame trips it.
  # The designed broadcast replay client, embedded at compile time. Final
  # in-page script order: wire constants, shared chrome, core, page IIFE.
  EmbeddedBroadcastReplayHtml = staticRead("../../client/replay_broadcast.html").replace(
    "<!-- CHROME_COMMON -->",
    "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
  ).replace(
    "<!-- BROADCAST_CORE -->",
    "<script>" & staticRead("../../client/broadcast_core.js") & "</script>"
  ).spliceWireConstants()
  EmbeddedLeagueReplayerHtml = staticRead("../../client/league_replayer.html").replace(
    "<!-- CHROME_COMMON -->",
    "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
  ).spliceWireConstants()
  BroadcastFont = staticRead("../../data/font.ttf")

var appState: WebSocketAppState
var replayBytesForClients {.threadvar.}: string

proc initAppState() =
  initLock(appState.lock)
  appState.chatMessages = initTable[WebSocket, string]()
  appState.authenticatedPlayers = initTable[WebSocket, int]()
  appState.actionMessages = initTable[WebSocket, seq[PrivatePlayerMessage]]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerAddresses = initTable[WebSocket, string]()
  appState.playerSlots = initTable[WebSocket, int]()
  appState.playerTokens = initTable[WebSocket, string]()
  appState.playerReady = initTable[WebSocket, bool]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.closedSockets = @[]
  appState.nextAnonymousPlayer = 1
  appState.config = defaultGameConfig()

proc markSocketClosed(websocket: WebSocket): bool =
  result = websocket notin appState.closedSockets
  if result:
    appState.closedSockets.add(websocket)

proc disconnectWebSocket(websocket: WebSocket) =
  when defined(posix):
    let fields = cast[WebSocketSocketFields](websocket)
    discard shutdown(fields.clientSocket, SHUT_RDWR)
  else:
    websocket.close()

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc cleanPlayerName(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc playerSlotOf(request: Request): int =
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return MaxPlayers
  if result < 0 or result >= MaxPlayers:
    return MaxPlayers

proc playerTokenOf(request: Request): string =
  request.queryParams.getOrDefault("token", "").strip()

proc nextAnonymousPlayerIdentity(): string =
  {.gcsafe.}:
    withLock appState.lock:
      if appState.nextAnonymousPlayer <= 0:
        appState.nextAnonymousPlayer = 1
      result = "Player" & $appState.nextAnonymousPlayer
      inc appState.nextAnonymousPlayer

proc playerIdentity(request: Request, slot: int, token: string): string =
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.configuredPlayerName(slot, token)
      if result.len > 0:
        return
  result = nextAnonymousPlayerIdentity()

proc respondForbiddenWebSocket(request: Request, reason: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(403, headers, reason & "\n")

proc hasPlayerCredentialParams(request: Request): bool =
  request.queryParams.getOrDefault("name", "").strip().len > 0 or
    request.queryParams.getOrDefault("slot", "").strip().len > 0 or
    request.queryParams.getOrDefault("token", "").strip().len > 0

proc joinError(
  config: GameConfig,
  address: string,
  slot: int,
  token: string
): string =
  if config.playerJoinAllowed(address, slot, token):
    return ""
  if slot >= MaxPlayers:
    return "Player slot must be between 0 and " & $(MaxPlayers - 1) & "."
  if slot >= 0 and slot < config.slots.len and
      config.slots[slot].token.len > 0 and token != config.slots[slot].token:
    return "Player token does not match configured slot " & $slot & "."
  "Player credentials do not match configured roster."

proc readSpriteChatRaw(message: string): string =
  ## Reads a Sprite v1 chat packet's payload WITHOUT the ASCII filter
  ## `parseSpriteClientMessages` applies. Registration is JSON that may carry
  ## a non-ASCII policy label, and the whole point of the rune discipline is
  ## that such a label survives to the replay intact.
  if message.len < 3 or message[0].uint8 != SpriteClientChat:
    return ""
  let length = int(uint16(message[1].uint8) or (uint16(message[2].uint8) shl 8))
  if 3 + length > message.len:
    return ""
  message[3 ..< 3 + length]

proc isPlayerReadyPacket(message: string): bool =
  message.len == 1 and message[0].uint8 == SpriteClientReady

proc httpHandler(request: Request) =
  if request.path == HealthPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, "healthy")
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      slot = request.playerSlotOf()
      token = request.playerTokenOf()
      identity = request.playerIdentity(slot, token)
    {.gcsafe.}:
      withLock appState.lock:
        let error = appState.config.joinError(identity, slot, token)
        if error.len > 0 or appState.started or appState.stopping or appState.sealed:
          request.respondForbiddenWebSocket("player admission is closed or invalid")
          return
        for live, liveSlot in appState.authenticatedPlayers:
          if slot >= 0 and liveSlot == slot and live in appState.playerViewers and
              live notin appState.closedSockets:
            request.respondForbiddenWebSocket("player seat is already connected")
            return
        let websocket = request.upgradeToWebSocket()
        appState.authenticatedPlayers[websocket] = slot
        appState.globalViewers.del(websocket)
        appState.playerViewers[websocket] = initPlayerViewerState()
        appState.playerAddresses[websocket] = identity
        appState.playerSlots[websocket] = slot
        appState.playerTokens[websocket] = token
        appState.playerIndices[websocket] =
          if appState.replayLoaded: -1 else: 0x7fffffff
        appState.playerReady[websocket] = false
    echo "player connected: ", identity
  elif request.path in [GlobalWebSocketPath, ReplayWebSocketPath] and
      request.httpMethod == "GET" and request.isWebSocketUpgrade():
    if request.hasPlayerCredentialParams():
      request.respondForbiddenWebSocket(
        "Viewer websocket cannot include player name, slot, or token.")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = initGlobalViewerState()
  elif request.path == BroadcastFontPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "font/ttf"
    headers["Cache-Control"] = "public, max-age=3600"
    request.respond(200, headers, BroadcastFont)
  elif request.path == ReplayDataPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "application/octet-stream"
    headers["Cache-Control"] = "no-cache"
    {.gcsafe.}:
      request.respond(200, headers, replayBytesForClients)
  elif request.path in [
      bitworldClient.ReplayClientRoute,
      bitworldClient.CoworldReplayClientRoute,
      LeagueReplayerPath
    ] and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    if request.path == LeagueReplayerPath:
      request.respond(200, headers, EmbeddedLeagueReplayerHtml)
    else:
      request.respond(200, headers, EmbeddedBroadcastReplayHtml)
  elif bitworldClient.serveClientRoute(
      request, bitworldClient.GlobalClientRoute):
    discard
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "cogball server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    if message.kind == Ping:
      websocket.send(message.data, Pong)
    elif message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if message.data.isPlayerReadyPacket() and
              websocket in appState.playerReady:
            appState.playerReady[websocket] = true
          elif websocket in appState.globalViewers:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data)
          elif websocket in appState.playerViewers and not appState.started and
              not appState.stopping and not appState.sealed:
            # EDIT 3: a seat's chat is its registration. Read the raw payload
            # so a non-ASCII policy label survives; the input bits a seat may
            # send are read and dropped (the server computes every mask).
            let text = readSpriteChatRaw(message.data)
            if text.len > 0:
              appState.chatMessages[websocket] = text
    elif message.kind == TextMessage:
      let receivedAt = getMonoTime()
      {.gcsafe.}:
        withLock appState.lock:
          if websocket in appState.authenticatedPlayers and not appState.sealed:
            appState.actionMessages.mgetOrPut(websocket, @[]).add(
              PrivatePlayerMessage(data: message.data, receivedAt: receivedAt))
  of ErrorEvent, CloseEvent:
    var who = ""
    {.gcsafe.}:
      withLock appState.lock:
        if markSocketClosed(websocket) and
            websocket in appState.playerAddresses:
          who = appState.playerAddresses[websocket]
    if who.len > 0:
      echo "player disconnected: ", who

type FrameAdvance = enum
  LateFrame, SkippedFrame, WaitedFrame

proc allPlayersReady(
  sockets: openArray[WebSocket],
  playerIndices: openArray[int],
  playerCount: int
): bool =
  var active = 0
  {.gcsafe.}:
    withLock appState.lock:
      for i, websocket in sockets:
        if i >= playerIndices.len or playerIndices[i] < 0 or
            playerIndices[i] >= playerCount:
          continue
        inc active
        if not appState.playerReady.getOrDefault(websocket, false):
          return false
  active > 0

proc runFrameLimiter(
  previousTick: var MonoTime,
  fastMode: bool,
  sockets: openArray[WebSocket],
  playerIndices: openArray[int],
  playerCount: int
): FrameAdvance =
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  var slept = false
  while true:
    let elapsed = getMonoTime() - previousTick
    if elapsed >= frameDuration:
      result = if slept: WaitedFrame else: LateFrame
      break
    if fastMode and sockets.allPlayersReady(playerIndices, playerCount):
      result = SkippedFrame
      break
    let remaining = frameDuration - elapsed
    sleep(max(1, min(2, int(remaining.inMilliseconds))))
    slept = true
  previousTick = getMonoTime()

proc declarePlayerFailure*(slot: int, message: string, deadline: MonoTime) =
  ## The platform polls this source-owned no-show declaration.
  let uri = getEnv("COGAME_PLAYER_FAILURE_URI")
  if uri.len > 0:
    writeCogameArtifact(uri, $(%*{"failed_policy_index": slot, "message": message}),
      "application/json", "COGAME_PLAYER_FAILURE_URI", deadline)

proc parseRegistration*(text: string): tuple[ok: bool, node: JsonNode] =
  try:
    let node = parseJson(text)
    if node.kind == JObject and node{"type"}.getStr() == "register":
      return (true, node)
  except CatchableError:
    discard
  (false, newJNull())

proc registrationOf*(
  text: string,
  seat: Seat,
  previous: SeatPolicy
): tuple[ok: bool, policy: SeatPolicy, record: string] =
  ## EDIT 3, as a pure function: one chat payload from a seat becomes a policy
  ## and, when it CHANGES that seat's policy, the redacted `register` record
  ## the replay carries. Nothing here echoes the payload, and any text that is not a
  ## registration object is dropped (`ok` false, no record).
  ##
  ## Exported so tests/test_server.nim can assert the contract on the SAME code
  ## the loop runs, instead of re-implementing the predicate beside it.
  let parsed = parseRegistration(text)
  if not parsed.ok:
    return (false, previous, "")
  var policy = SeatPolicy(connected: true)
  let kind = parsed.node{"kind"}.getStr()
  let scripted = parsed.node{"scripted"}
  let label = clipRunes(parsed.node{"policy"}.getStr(), MaxPolicyRunes)
  if kind in ["prompt", "external"]:
    if parsed.node["prompt"].kind != JString or parsed.node["prompt"].getStr().len > 4000:
      return (false, previous, "")
    policy.operatorPrompt = parsed.node["prompt"].getStr()
    policy.kind = pkLlm
    policy.baseline = ""
  else:
    policy.kind = pkScripted
    policy.baseline =
      if scripted.kind == JString and scripted.getStr().len > 0:
        scripted.getStr()
      else:
        "formation"
  policy.label = if label.len > 0: label else: policyKindText(policy.kind)
  # Only an actual policy change earns another record.
  let unchanged =
    previous.connected and
    previous.kind == policy.kind and
    previous.baseline == policy.baseline and
    previous.label == policy.label and
    previous.operatorPrompt == policy.operatorPrompt
  if unchanged:
    return (true, policy, "")
  (true, policy, $(%*{
    "k": "register",
    "seat": ord(seat),
    "alias": seatAlias(seat),
    "policy": policy.label,
    "kind": policyKindText(policy.kind),
    "baseline": policy.baseline
  }))

type
  PrivateFrameKind = enum
    pfIgnored, pfStarted, pfAction, pfStopped, pfRejected
  PrivateFrame = object
    kind: PrivateFrameKind
    payload: JsonNode

proc takeMessages(socket: WebSocket): seq[PrivatePlayerMessage] {.gcsafe.} =
  {.gcsafe.}:
    withLock appState.lock:
      if appState.actionMessages.hasKey(socket):
        result = appState.actionMessages[socket]
        appState.actionMessages.del(socket)

proc consumePrivateFrame(exchange: NativeExchange, socket: WebSocket,
    received: PrivatePlayerMessage, current: Option[IssuedOperation]): PrivateFrame =
  result.payload = newJNull()
  var answer = newJNull()
  try:
    answer = parseJson(received.data)
    let kind = answer["type"].getStr()
    if kind == "stopped":
      if answer["attempts"].kind != JArray or
          answer["worker_status"].getStr() notin ["joined", "no_active_call"] or
          answer["decision_id"].kind notin {JString, JNull} or
          answer["stop_id"].kind notin {JString, JNull}:
        raise newException(CogballError, "invalid native reader acknowledgement")
      for payload in answer["attempts"]:
        let attemptId = payload["attempt_id"].getStr()
        var matched = false
        for issued in exchange.operations:
          if issued.socket == socket and attemptId == issued.id & "-" & $ord(issued.seat):
            discard exchange.retainAttempt(socket, issued.id, payload, received.receivedAt, nesReceived)
            matched = true
            break
        if not matched:
          raise newException(CogballError, "acknowledgement includes an unissued attempt")
      result.kind = pfStopped
      result.payload = answer
      return
    if kind notin ["action", "attempt_started"]: return
    let id = answer["decision_id"].getStr()
    let issued = exchange.operation(socket, id)
    if answer.hasKey("training_attempt") and answer["training_attempt"].kind != JNull:
      discard exchange.retainAttempt(socket, id, answer["training_attempt"], received.receivedAt,
        if kind == "attempt_started": nesStarted else: nesReceived)
    if kind == "attempt_started":
      result.kind = pfStarted
      return
    if current.isNone or issued != current.get() or
        received.receivedAt < issued.issuedAt or received.receivedAt > issued.deadline:
      return
    if answer.hasKey("action") and answer["action"].kind == JObject and issued.evidence.isSome:
      issued.validateModelAction()
    result.kind = pfAction
    result.payload = answer
  except CatchableError:
    # The existing private parse boundary never attributes stale controls to a new action.
    if current.isSome and answer.kind == JObject and answer.hasKey("type") and
        answer["type"] == %"action" and answer.hasKey("decision_id") and
        answer["decision_id"] == %current.get().id and
        received.receivedAt >= current.get().issuedAt and received.receivedAt <= current.get().deadline:
      result.kind = pfRejected

proc confirmEvidenceReceipt(socket: WebSocket, payload: JsonNode) =
  var live: bool
  {.gcsafe.}:
    withLock appState.lock:
      live = socket in appState.playerViewers and socket notin appState.closedSockets
  if live:
    socket.send($(%*{"type": "evidence_received", "decision_id": payload["decision_id"],
      "stop_id": payload["stop_id"]}), TextMessage)

proc playerBatch(
  seatSockets: array[Seat, WebSocket],
  seatConnected: array[Seat, bool], exchange: NativeExchange,
  publishWaitingFrame: proc() {.closure, gcsafe.}
): BatchFn =
  result = proc(calls: seq[BatchCall], deadline: MonoTime): seq[BatchReply]
      {.closure, gcsafe.} =
    result = newSeq[BatchReply](calls.len)
    var issuedCalls: seq[IssuedOperation]
    for position, call in calls:
      let socket = seatSockets[Seat(call.seat)]
      let issued = exchange.issue(socket, Seat(call.seat), call, deadline)
      issuedCalls.add(issued)
      result[position].seat = call.seat
      result[position].attemptId = issued.id & "-" & $call.seat
      if not seatConnected[Seat(call.seat)]:
        result[position].error = "player disconnected"
        continue
      socket.send($( %*{"type": "decision", "decision_id": issued.id,
        "seat": call.seat, "observation": call.observation,
        "messages": [{"role": "system", "content": call.system},
          {"role": "user", "content": call.user}],
        "transport": {"budget_ms": max(0'i64, (deadline - getMonoTime()).inMilliseconds),
          "cleanup_budget_ms": 5000, "max_output_tokens": call.maxOutputTokens}}), TextMessage)
    var nextWaitingFrame = getMonoTime()
    while not interruptionRequested() and getMonoTime() < deadline:
      if getMonoTime() >= nextWaitingFrame:
        publishWaitingFrame()
        nextWaitingFrame = getMonoTime() + initDuration(milliseconds = 100)
      var pending = false
      for position, issued in issuedCalls:
        if result[position].ok or result[position].error.len > 0: continue
        for received in takeMessages(issued.socket):
          let frame = consumePrivateFrame(exchange, issued.socket, received, some(issued))
          result[position].evidence = issued.evidence
          case frame.kind
          of pfAction:
            if frame.payload.hasKey("action") and frame.payload["action"].kind == JObject:
              result[position].ok = true
              result[position].text = $frame.payload["action"]
            else:
              result[position].error = "model attempt failed"
              let cause = frame.payload{"cause"}.getStr()
              result[position].cause = if cause in ["no_credentials", "timeout", "parse_error"]:
                cause else: "transport_error"
          of pfStopped:
            confirmEvidenceReceipt(issued.socket, frame.payload)
            if frame.payload["decision_id"] == %issued.id:
              result[position].error = "player stopped before action"
          of pfRejected: result[position].error = "invalid player response"
          else: discard
        if not result[position].ok and result[position].error.len == 0: pending = true
      if not pending: break
      sleep(10)
    for position, reply in result.mpairs:
      reply.evidence = issuedCalls[position].evidence
      if not reply.ok and reply.error.len == 0: reply.error = "Timeout was reached"

proc writeInitializationCheckpoint*(config: GameConfig, status: EpisodeStatus) =
  doAssert status in {esFailed, esTruncated}
  let uri = getEnv(CogameSaveTrajectoryUriEnv)
  if uri.len == 0: return
  requestNativeStop()
  let deadline = getMonoTime() + initDuration(milliseconds = 5000)
  let trajectory = newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"),
    "cogball-" & $config.seed, "cogball", getEnv("COWORLD_GAME_VERSION"),
    getEnv("COWORLD_SOURCE_REVISION"))
  trajectory.finish(status, %*{"reason": "runtime_initialization",
    "engine_version": GameVersion}, newJNull())
  let methodName = getEnv("COGAME_SAVE_TRAJECTORY_METHOD", "PUT")
  let methodValue = case methodName
    of "PUT": ahPut
    of "POST": ahPost
    else: raise newException(ValueError, "trajectory method must be PUT or POST")
  trajectory.writeTrajectoryArtifact(uri, deadline, methodValue)

proc runGameLoop(
  httpServer: Server,
  episodeStart: MonoTime,
  initialConfig = defaultGameConfig(),
  saveReplayPath = "",
  loadReplayPath = "",
  saveScoresPath = "",
  runtimeConfig = RuntimeConfig()
) =
  var ownerReady = false
  defer:
    if not ownerReady:
      initialConfig.writeInitializationCheckpoint(if interruptionRequested(): esTruncated else: esFailed)
  if saveReplayPath.len > 0 and loadReplayPath.len > 0:
    raise newException(ReplayError, "Cannot save and load a replay together")
  var replayLoaded = loadReplayPath.len > 0
  var replayData =
    if replayLoaded:
      try:
        loadReplay(loadReplayPath)
      except CatchableError as e:
        echo "replay load failed (serving without replay): ", e.msg
        replayLoaded = false
        ReplayData()
    else:
      ReplayData()
  var initializedReplay =
    if replayLoaded: initReplayRuntime(replayData, runtimeConfig.mismatchQuit)
    else: InitializedReplay()
  var config =
    if replayLoaded: move(initializedReplay.config) else: initialConfig
  var
    replayWriter = openReplayWriter(saveReplayPath, config.configJson())
    replayPlayer =
      if replayLoaded: move(initializedReplay.player) else: ReplayPlayer()
  defer:
    replayWriter.closeReplayWriter()
  withLock appState.lock:
    appState.replayLoaded = replayLoaded
    appState.replayServerMode = replayLoaded
    appState.config = config

  let eventsPath = block:
    let uri = getEnv("COGAME_EVENTS_URI")
    if uri.len == 0: ""
    elif uri.startsWith("file://"): uri[7 .. ^1]
    else:
      raise newException(ValueError,
        "COGAME_EVENTS_URI must use a file:// path")

  var
    sim =
      if replayLoaded: move(initializedReplay.sim) else: initSimServer(config)
    lastTick = getMonoTime()
    collectedEvents: seq[SimEvent] = @[]
  sim.collectEvents = eventsPath.len > 0
  replayWriter.lastMasks = newSeq[uint8](RobotCount)

  block:
    # The game owner bakes rendering before publishing its first frame.
    # Listener readiness starts the viewer deadline; the real runtime gate
    # verifies this initialization and first canonical frame together.
    let warmStart = getMonoTime()
    sim.warmBoardRenderCaches()
    echo "board render caches baked in ",
      (getMonoTime() - warmStart).inMilliseconds,
      " ms (charged against wallClockBudgetSeconds=",
      config.wallClockBudgetSeconds, ")"

  let exchange = newNativeExchange()
  var engine = newTurnEngine(nil)
  for seat in Seat:
    engine.policies[seat] = SeatPolicy(
      kind: pkScripted, baseline: "formation", label: "formation")

  let trajectoryUri = getEnv(CogameSaveTrajectoryUriEnv)
  let capture = if trajectoryUri.len > 0 and not replayLoaded:
    some(newMatchCapture(getEnv("COWORLD_EPISODE_ID"),
      getEnv("COWORLD_GAME_VERSION"), getEnv("COWORLD_SOURCE_REVISION"), config.seed))
    else: none(MatchCapture)

  var
    prevInputs = newSeq[InputState](RobotCount)
    liveSpeedIndex = 0
    broadcastTracker =
      if replayLoaded: move(initializedReplay.tracker)
      else: initBroadcastTracker()
    quitAfterFrame = false
    failureDeclared = false
    episodeDeadlineReached = false
    lastGoalsSeen: array[Seat, int32]
    resultRecordWritten = false

  proc recordAndWrite(text: string) =
    ## The ONE path a chat record takes: capped, into the replay AND back
    ## through `applyRecord`, so the broadcast feed reads identically live and
    ## in playback. The cap is applied HERE, not only in `engine.addRecord`, so
    ## `register` and `result` obey it too -- a long policy name is otherwise
    ## unbounded on its way to the replay. `capRecord` shrinks structurally, so
    ## a record over the cap stays parseable JSON.
    let record = capRecord(text)
    replayWriter.writeChat(tickTime(sim.tickCount), 0, record)
    sim.applyRecord(record)

  proc publishGlobalFrame(frameEvents: JsonNode) =
    var globalViewers: seq[WebSocket]
    var globalStates: seq[GlobalViewerState]
    {.gcsafe.}:
      withLock appState.lock:
        for websocket, state in appState.globalViewers.pairs:
          globalViewers.add(websocket)
          var snapshot = state
          # Commands stay queued in appState until the owner applies them.
          # Packet construction must not duplicate them during a frozen wait.
          snapshot.replayCommands = @[]
          snapshot.replaySeekTick = -1
          globalStates.add(snapshot)
    for i in 0 ..< globalViewers.len:
      var nextState: GlobalViewerState
      var packet =
        if replayLoaded:
          sim.buildReplayViewerPacket(
            replayPlayer, globalStates[i], nextState, frameEvents)
        else:
          sim.buildSpriteProtocolUpdates(
            globalStates[i], nextState, sim.tickCount, true,
            playbackSpeed(liveSpeedIndex), config.maxTicks, false, false, -1)
      if not replayLoaded:
        # The chrome channel rides the SAME binary sprite stream as the board,
        # as the label of a reserved never-drawn 1x1 sprite, because that is
        # the only channel that survives a hosted replay.
        packet.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0],
          sim.buildStateJson(frameEvents, true,
            float(playbackSpeed(liveSpeedIndex)), config.maxTicks, false,
            false, -1,
            -1, @[], 0, 0, false, false, false, @[], nil))
      if packet.len == 0:
        continue
      try:
        for chunk in chunkSpritePacket(packet, MaxWsFrameBytes):
          globalViewers[i].send(blobFromBytes(chunk), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if globalViewers[i] in appState.globalViewers:
              let pending = appState.globalViewers[globalViewers[i]]
              var merged = nextState
              merged.mouseX = pending.mouseX
              merged.mouseY = pending.mouseY
              merged.mouseLayer = pending.mouseLayer
              merged.mouseDown = pending.mouseDown
              if pending.clickPending:
                merged.clickPending = true
              if pending.replaySeekTick >= 0:
                merged.replaySeekTick = pending.replaySeekTick
              if pending.replayCommands.len > 0:
                merged.replayCommands.add(pending.replayCommands)
              appState.globalViewers[globalViewers[i]] = merged
      except:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(globalViewers[i])

  var finalizationStarted = false
  proc writeArtifacts(requestedStatus: EpisodeStatus) =
    # Mark the seal before any operation that can fail; never retry a partial seal.
    finalizationStarted = true
    let cleanupDeadline = getMonoTime() + initDuration(milliseconds = 5000)
    let acknowledgementDeadline = cleanupDeadline - initDuration(milliseconds = 1000)
    let issuedStopAt = getMonoTime()
    var stopId: string
    for value in urandom(16): stopId.add(toHex(value, 2).toLowerAscii())
    withLock appState.lock:
      appState.stopping = true
      for socket, slot in appState.authenticatedPlayers: exchange.targets[socket] = slot
    requestNativeStop()
    for socket, slot in exchange.targets:
      var live: bool
      withLock appState.lock:
        live = socket in appState.playerViewers and socket notin appState.closedSockets
      if live:
        socket.send($(%*{"type": "stop", "decision_id":
          (if exchange.latest.hasKey(socket): %exchange.latest[socket] else: newJNull()),
          "stop_id": stopId,
          "cleanup_budget_ms": max(0'i64, (acknowledgementDeadline - getMonoTime()).inMilliseconds)}), TextMessage)
    var acknowledged = initHashSet[WebSocket]()
    while getMonoTime() < acknowledgementDeadline:
      for socket, slot in exchange.targets:
        for received in takeMessages(socket):
          let frame = consumePrivateFrame(exchange, socket, received, none(IssuedOperation))
          if frame.kind != pfStopped: continue
          # Retain genuine older-operation facts before checking current stop credit.
          confirmEvidenceReceipt(socket, frame.payload)
          let latest = if exchange.latest.hasKey(socket): %exchange.latest[socket] else: newJNull()
          if received.receivedAt < issuedStopAt or received.receivedAt > acknowledgementDeadline or
              frame.payload["stop_id"] != %stopId or frame.payload["decision_id"] != latest:
            continue
          var allReadersJoined = true
          for issued in exchange.operations:
            if issued.socket == socket and issued.started and
                (issued.evidence.isNone or issued.evidence.get().responseReaderJoined != some(true)):
              allReadersJoined = false
          if allReadersJoined: acknowledged.incl(socket)
      if acknowledged.len == exchange.targets.len: break
      sleep(10)
    var cleanup = newJArray()
    for socket, slot in exchange.targets:
      cleanup.add(%*{"seat": slot,
        "decision_id": (if exchange.latest.hasKey(socket): %exchange.latest[socket] else: newJNull()),
        "status": (if socket in acknowledged: "acknowledged" else: "unresolved")})
    var status = requestedStatus
    if status == esCompleted and acknowledged.len != exchange.targets.len: status = esTruncated
    withLock appState.lock: appState.sealed = true
    replayWriter.closeReplayWriter()
    if capture.isSome:
      capture.get().finishMatch(sim, status, cleanup, exchange.finalAttempts())
      let methodName = getEnv("COGAME_SAVE_TRAJECTORY_METHOD", "PUT")
      let methodValue = case methodName
        of "PUT": ahPut
        of "POST": ahPost
        else: raise newException(ValueError, "trajectory method must be PUT or POST")
      capture.get().trajectory.writeTrajectoryArtifact(trajectoryUri, cleanupDeadline, methodValue)
    if status != esCompleted: return
    if runtimeConfig.replayUri.len > 0:
      writeCogameArtifact(runtimeConfig.replayUri, readFile(saveReplayPath),
        "application/octet-stream", CogameSaveReplayUriEnv, cleanupDeadline)
    if eventsPath.len > 0:
      writeCogameArtifact("file://" & eventsPath, collectedEvents.eventsJsonl(sim.tickCount),
        "application/x-ndjson", "COGAME_EVENTS_URI", cleanupDeadline)
    if runtimeConfig.resultsUri.len > 0:
      writeCogameArtifact(runtimeConfig.resultsUri, sim.playerResultsJson() & "\n",
        "application/json", CogameResultsUriEnv, cleanupDeadline)
    elif saveScoresPath.len > 0:
      writeCogameArtifact("file://" & saveScoresPath, sim.playerResultsJson() & "\n",
        "application/json", CogameResultsUriEnv, cleanupDeadline)
    echo "Results: ", sim.playerResultsJson()

  ownerReady = true
  try:
    while not interruptionRequested():
      if not replayLoaded and getMonoTime() >= episodeStart + initDuration(seconds = config.wallClockBudgetSeconds):
        episodeDeadlineReached = true
        sim.wallClockStop()
        break
      var
        sockets: seq[WebSocket] = @[]
        playerIndices: seq[int] = @[]
        playerViewerStates: seq[PlayerViewerState] = @[]
        replayCommands: seq[char] = @[]
        replaySeekTicks: seq[int] = @[]
        registrations: seq[tuple[seat: int, text: string]] = @[]

      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.closedSockets:
            if not replayLoaded and websocket in appState.playerIndices:
              let index = appState.playerIndices[websocket]
              if index >= 0 and index < sim.players.len:
                sim.recordGameAbandon(index)
                replayWriter.writeLeave(tickTime(sim.tickCount), index)
                sim.removePlayerAt(index)
                for ws, value in appState.playerIndices.mpairs:
                  if value > index:
                    dec value
            appState.playerViewers.del(websocket)
            appState.playerIndices.del(websocket)
            appState.playerAddresses.del(websocket)
            appState.playerSlots.del(websocket)
            appState.playerTokens.del(websocket)
            appState.playerReady.del(websocket)
            appState.chatMessages.del(websocket)
            appState.globalViewers.del(websocket)
          # Authenticated socket bindings survive close ordering until the private seal.
          appState.closedSockets.setLen(0)
          for websocket, seat in appState.authenticatedPlayers:
            exchange.targets[websocket] = seat

          if not replayLoaded:
            # Joins are strictly slot-sequential.
            var progressed = true
            while progressed:
              progressed = false
              for websocket in appState.playerIndices.keys:
                if appState.playerIndices[websocket] != 0x7fffffff:
                  continue
                if sim.phase != Lobby or not sim.canAddPlayer():
                  appState.playerIndices[websocket] = -1
                  continue
                let
                  address = appState.playerAddresses.getOrDefault(
                    websocket, "unknown")
                  slot = appState.playerSlots.getOrDefault(websocket, -1)
                  token = appState.playerTokens.getOrDefault(websocket, "")
                  resolved = sim.resolvePlayerSlot(address, token, slot)
                if resolved != sim.nextPlayerSlot():
                  continue
                try:
                  let index = sim.addPlayer(address, resolved, token)
                  appState.playerIndices[websocket] = index
                  appState.authenticatedPlayers[websocket] = ord(sim.players[index].seat)
                  replayWriter.writeJoin(tickTime(sim.tickCount), index,
                    address, resolved, token)
                  progressed = true
                except CogballError:
                  appState.playerIndices[websocket] = -1
                break

          for websocket, index in appState.playerIndices.pairs:
            if websocket notin appState.playerViewers:
              continue
            sockets.add(websocket)
            playerIndices.add(index)
            playerViewerStates.add(appState.playerViewers[websocket])
            if index >= 0 and index < sim.players.len:
              let text = appState.chatMessages.getOrDefault(websocket, "")
              if text.len > 0:
                registrations.add((ord(sim.players[index].seat), text))
              appState.chatMessages.del(websocket)
            elif index < 0:
              appState.chatMessages.del(websocket)

          for websocket, state in appState.globalViewers.pairs:
            if state.replaySeekTick >= 0:
              replaySeekTicks.add(state.replaySeekTick)
            for command in state.replayCommands:
              replayCommands.add(command)
            appState.globalViewers[websocket].replayCommands.setLen(0)
            appState.globalViewers[websocket].replaySeekTick = -1

      # EDIT 3: registration is consumed here and NEVER written to the replay
      # chat stream. `registrationOf` returns the redacted `register` record
      # instead, and returns nothing at all for any other chat text.
      for entry in registrations:
        if sim.phase != Lobby: break
        let seat = Seat(entry.seat and 1)
        let reg = registrationOf(entry.text, seat, engine.policies[seat])
        if not reg.ok:
          continue                     ## any other chat text is dropped.
        engine.policies[seat] = reg.policy
        if reg.record.len == 0:
          continue                     ## an unchanged re-send earns no record.
        let index = sim.playerFor(seat)
        if index >= 0:
          sim.players[index].policyKind = reg.policy.kind
          sim.players[index].baseline = reg.policy.baseline
          sim.players[index].policyLabel = reg.policy.label
          sim.players[index].registered = true
        recordAndWrite(reg.record)

      # A seat that never connects does NOT end the episode: the no-show is
      # declared, its trio plays the `formation` baseline, and the match runs to
      # full time.
      if not replayLoaded and sim.lobbyJoinTimedOut() and not failureDeclared:
        failureDeclared = true
        let stuck = sim.nextPlayerSlot()
        declarePlayerFailure(stuck,
          "player slot " & $stuck & " never joined the lobby within " &
            $config.lobbyJoinTimeoutTicks & " lobby ticks (~" &
            $(config.lobbyJoinTimeoutTicks div TargetFps) & "s)",
          min(episodeStart + initDuration(seconds = config.wallClockBudgetSeconds),
            getMonoTime() + initDuration(milliseconds = 5000)))
        echo "cogball: lobby join timeout on slot ", stuck,
          "; starting with the scripted baseline in that seat"
        sim.startGame()

      var frameEvents = newJArray()
      if replayLoaded:
        frameEvents = replayPlayer.advanceReplayFrame(
          sim, broadcastTracker, replaySeekTicks, replayCommands)
      else:
        for command in replayCommands:
          liveSpeedIndex.applySpeedCommand(command)
        for _ in 0 ..< playbackSpeed(liveSpeedIndex):
          if sim.phase == GameOver and sim.gameOverTimer <= 0:
            break
          # EDIT 4: the wall-clock stop. Inside the tick loop, not once per
          # outer iteration: a spectator can raise liveSpeedIndex to 5, which
          # steps up to 16 ticks per iteration, and the stop must not be
          # coarser than the thing it is stopping.
          if sim.phase == Playing:
            let elapsed = int((getMonoTime() - episodeStart).inSeconds)
            if elapsed >= config.wallClockBudgetSeconds:
              echo "cogball: wall-clock budget reached at ", elapsed,
                "s; stopping"
              sim.wallClockStop()
          # EDIT 2: the turn boundary, immediately before the tick it governs.
          if sim.phase == Playing:
            let elapsedTicks = sim.tickCount - sim.gameStartTick
            # The phase flips INSIDE a step, so the first Playing tick is never a
            # boundary. Turn 0 therefore fires on the first tick that has no
            # directive yet — otherwise the opening five seconds would be played
            # on the compiled-in default.
            let opening = not (sim.hasDirective[Azure] and sim.hasDirective[Crimson])
            if opening or elapsedTicks mod sim.turnTicks() == 0:
              let seconds = int((getMonoTime() - episodeStart).inSeconds)
              var seatSockets: array[Seat, WebSocket]
              var seatConnected: array[Seat, bool]
              for i, index in playerIndices:
                if index >= 0 and index < sim.players.len:
                  let seat = sim.players[index].seat
                  seatSockets[seat] = sockets[i]
                  seatConnected[seat] = true
              engine.batch = playerBatch(seatSockets, seatConnected, exchange,
                proc() {.closure, gcsafe.} =
                  {.cast(gcsafe).}: publishGlobalFrame(newJArray()))
              engine.turn(sim, elapsedTicks div sim.turnTicks(), seconds)
              if capture.isSome: capture.get().beginTurn(engine, sim)
              if interruptionRequested(): break
              for record in engine.records:
                recordAndWrite(record)
          if interruptionRequested(): break
          # Connected seats register before the lobby countdown can start play.
          # The existing lobby allowance bounds a silent connected player too.
          if sim.phase == Lobby:
            var awaitingRegistration = false
            for player in sim.players:
              if not player.registered: awaitingRegistration = true
            if awaitingRegistration and getMonoTime() < episodeStart +
                initDuration(milliseconds = config.lobbyJoinTimeoutTicks * 1000 div TargetFps):
              break
          # EDIT 1: the input source is the control layer, not the socket.
          let masks = sim.compileMasks(sim.activeDirective)
          replayWriter.writeInputFrameMasks(tickTime(sim.tickCount), masks)
          var inputs = newSeq[InputState](RobotCount)
          for i in 0 ..< RobotCount:
            inputs[i] = decodeInputMask(masks[i])
          if sim.phase == Lobby:
            {.gcsafe.}:
              withLock appState.lock:
                sim.step(inputs, prevInputs)
                if sim.phase != Lobby: appState.started = true
          else:
            sim.step(inputs, prevInputs)
          if capture.isSome: capture.get().recordTick(masks, sim)
          prevInputs = inputs
          replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())
          if sim.collectEvents:
            for event in sim.events:
              collectedEvents.add(event)
            sim.events.setLen(0)
          for seat in Seat:
            if sim.stats[seat].goals > lastGoalsSeen[seat]:
              lastGoalsSeen[seat] = sim.stats[seat].goals
              engine.noteGoal(sim.tickCount, int(sim.lastGoalBy), seat)
          sim.stepEvents(broadcastTracker, frameEvents)
          if sim.phase == GameOver and sim.gameOverTimer <= 0:
            # The `result` record is written at the very END, so its finalTick is
            # the same number results.json reports.
            if not resultRecordWritten:
              resultRecordWritten = true
              recordAndWrite(sim.resultRecordJson())
            quitAfterFrame = true
            break

      for i in 0 ..< sockets.len:
        var nextState: PlayerViewerState
        let framePacket = sim.buildSpriteProtocolPlayerUpdates(
          playerIndices[i], playerViewerStates[i], nextState)
        {.gcsafe.}:
          withLock appState.lock:
            if sockets[i] in appState.playerViewers:
              appState.playerViewers[sockets[i]] = nextState
              appState.playerReady[sockets[i]] = false
        let wirePacket = dedupObjectPlacements(framePacket,
          nextState.sentPlacements)
        try:
          if wirePacket.len == 0:
            sockets[i].send("", BinaryMessage)
          for chunk in chunkSpritePacket(wirePacket, MaxWsFrameBytes):
            sockets[i].send(blobFromBytes(chunk), BinaryMessage)
        except:
          {.gcsafe.}:
            withLock appState.lock:
              discard markSocketClosed(sockets[i])

      publishGlobalFrame(frameEvents)

      if quitAfterFrame:
        writeArtifacts(case sim.endReason
          of reasonComplete: esCompleted
          of reasonDeadline: esTruncated
          of reasonFault: esFailed)
        break

      discard runFrameLimiter(lastTick, not replayLoaded and config.fastMode,
        sockets, playerIndices, sim.players.len)
  finally:
    try:
      if not finalizationStarted:
        writeArtifacts(if interruptionRequested() or episodeDeadlineReached: esTruncated else: esFailed)
    finally:
      requestNativeStop()
      httpServer.close()

proc gameThreadProc(args: GameThreadArgs) {.thread.} =
  {.cast(gcsafe).}:
    runGameLoop(args.server[], args.episodeStart, args.initialConfig,
      args.saveReplayPath, args.loadReplayPath, args.saveScoresPath, args.runtimeConfig)

proc runServerLoop*(
  host = DefaultHost,
  port = DefaultPort,
  initialConfig = defaultGameConfig(),
  saveReplayPath = "",
  loadReplayPath = "",
  saveScoresPath = "",
  runtimeConfig = RuntimeConfig()
) =
  let episodeStart = getMonoTime()
  installNativeStopHandlers()
  initAppState()
  appState.config = initialConfig
  appState.replayServerMode = loadReplayPath.len > 0
  var gameStarted = false
  var startupInterrupted = false
  defer:
    if not gameStarted:
      initialConfig.writeInitializationCheckpoint(if startupInterrupted: esTruncated else: esFailed)
  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 4,
    maxMessageLen = 16 * 1024 * 1024)
  var gameThread: Thread[GameThreadArgs]
  let args = GameThreadArgs(server: cast[ptr Server](unsafeAddr httpServer),
    initialConfig: initialConfig, saveReplayPath: saveReplayPath,
    loadReplayPath: loadReplayPath, saveScoresPath: saveScoresPath,
    runtimeConfig: runtimeConfig, episodeStart: episodeStart)
  proc startGame(server: Server) {.gcsafe, raises: [ResourceExhaustedError].} =
    createThread(gameThread, gameThreadProc, args)
    gameStarted = true
  try:
    httpServer.serve(Port(port), host, onReady = startGame)
  finally:
    startupInterrupted = interruptionRequested()
    requestNativeStop()
    if gameStarted:
      joinThread(gameThread)
