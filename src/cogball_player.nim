## Cogball player: scripted and prompt policies use one wire protocol.
##
## Connects to the game and registers with one Sprite v1 chat message. The game
## sends private observations to this player. A prompt policy returns
## a JSON directive; the game validates it and computes the robot masks.
##
##   PLAYER_PROMPT=<strategy text>     -> an LLM seat
##   PLAYER_SCRIPTED=formation|swarm   -> a scripted seat
##   (none)                           -> PLAYER_SCRIPTED=formation
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <cogball-image> --name my-cogball \
##     --run /bin/cogball-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[atomics, json, locks, math, monotimes, options, os, strutils, times],
  bitworld/[decision_trajectory, native_http, native_stop, native_websocket],
  cogball/[llm, sim]

const
  SpriteClientChat = 0x81'u8
  SpriteClientReady = 0x85'u8
  ConnectTimeoutMs* = 90_000
    ## The game pod and the player pods are started together, so the game's
    ## listener may not be up when this process first dials: a refused connect
    ## at t=0 is NORMAL, not fatal. Retry until the listener appears, bounded,
    ## and then exit with a clean message rather than a traceback. Comfortably
    ## longer than the game's board bake plus its container start, and well
    ## inside lobbyJoinTimeoutTicks (2400 ticks = 100 s), so a seat that gives
    ## up here is a seat the lobby was about to declare missing anyway.
  ConnectRetryMs* = 250
  ReceiveTimeoutMs* = 120_000
    ## An explicit bound on the only blocking wait this process has. The game
    ## sends one frame per loop iteration at 24 Hz, and the longest legitimate
    ## gap is one coaching turn (turnBudgetMs, 9 s) plus scheduling, so two
    ## minutes of silence means the game pod is gone -- normally it closes the
    ## socket and the read returns, but a pod that dies without closing would
    ## otherwise leave this container blocked until the platform kills the
    ## episode. Degrade, never hang.

proc chatPacket(text: string): string =
  ## A Sprite v1 chat packet: type byte, u16 length, then the raw payload. The
  ## server reads the payload WITHOUT an ASCII filter, so a non-ASCII policy
  ## label survives to the replay intact.
  result = newString(3 + text.len)
  result[0] = char(SpriteClientChat)
  result[1] = char(text.len and 0xff)
  result[2] = char((text.len shr 8) and 0xff)
  for i, ch in text:
    result[3 + i] = ch

proc readyPacket(): string =
  result = newString(1)
  result[0] = char(SpriteClientReady)

proc connectWithRetry(url: string, deadline: MonoTime): WebSocketConnection =
  while not interruptionRequested() and getMonoTime() < deadline:
    result = connectNativeWebSocket(url, deadline, 16 * 1024 * 1024)
    if result.kind != wsFailure:
      return
    sleep(ConnectRetryMs)
  result.kind = if interruptionRequested(): wsInterrupted else: wsDeadline

type PlayerCall = object
  socket: ptr NativeWebSocket
  control: ptr NativeRequestControl
  decision: string
  deadline: MonoTime

var
  worker: Thread[PlayerCall]
  workerCreated = false
  workerFinished: Atomic[bool]
  evidenceLock: Lock
  workerEvidence: string
  requestControl: ptr NativeRequestControl

initLock(evidenceLock)

proc joinWorker(cancel: bool) =
  if workerCreated:
    if cancel: cancelNativeRequest(requestControl[])
    joinThread(worker)
    workerCreated = false
    deallocShared(requestControl)
    requestControl = nil

proc runDecision(call: PlayerCall) {.thread.} =
  defer: workerFinished.store(true)
  let decision = parseJson(call.decision)
  let identity = decision["decision_id"]
  var reply = %*{"type": "action", "decision_id": identity}
  var evidence = newDecisionAttempt(identity.getStr() & "-" &
    $decision["seat"].getInt(), "prompt-player", aoModel)
  var config = defaultGameConfig()
  config.maxOutputTokens = decision["transport"]["max_output_tokens"].getInt()
  let client = newLlmClient(config)
  if client.disabled:
    reply["cause"] = %"no_credentials"
    reply["error"] = %"no_credentials"
  else:
    try:
      let system = decision["messages"][0]["content"].getStr()
      let user = decision["messages"][1]["content"].getStr()
      evidence.prompt = copy(decision["messages"])
      let request = client.requestFor(system, user, decision["seat"].getInt())
      evidence.request = parseJson(request.body)
      evidence.model = some(client.model)
      evidence.decoder = %*{"temperature": client.temperature,
        "max_tokens": client.maxOutputTokens}
      {.gcsafe.}:
        withLock evidenceLock: workerEvidence = $attemptEvidenceJson(evidence)
      let announced = call.socket[].sendNativeText($( %*{"type": "attempt_started",
        "decision_id": identity, "training_attempt": attemptEvidenceJson(evidence)}), call.deadline)
      if announced.kind != wsReady:
        raise newException(CogballError, "native attempt start send failed")
      let response = performNativePost(request.url, request.headers,
        request.body, call.deadline, call.control[])
      let text = client.completionText(response, evidence)
      reply["action"] = extractJsonObject(text)
    except CatchableError as failure:
      reply["cause"] = %"transport_error"
      evidence.rejectionReason = some(failure.msg)
      reply["error"] = %"model attempt failed"
    reply["training_attempt"] = attemptEvidenceJson(evidence)
    {.gcsafe.}:
      withLock evidenceLock: workerEvidence = $attemptEvidenceJson(evidence)
  if not interruptionRequested():
    discard call.socket[].sendNativeText($reply, call.deadline)

proc startDecisionWorker(socket: var NativeWebSocket, decision: string, deadline: MonoTime) =
  let control = cast[ptr NativeRequestControl](allocShared0(sizeof(NativeRequestControl)))
  var transferred = false
  try:
    workerFinished.store(false)
    createThread(worker, runDecision, PlayerCall(socket: socket.addr,
      control: control, decision: decision, deadline: deadline))
    requestControl = control
    workerCreated = true
    transferred = true
  finally:
    if not transferred: deallocShared(control)

proc sendJoinedEvidence(socket: NativeWebSocket, decisionId, stopId: JsonNode,
    hadWorker: bool, deadline: MonoTime): WebSocketResult =
  var attempts = newJArray()
  withLock evidenceLock:
    if workerEvidence.len > 0: attempts.add(parseJson(workerEvidence))
  socket.sendCleanupText($(%*{"type": "stopped", "decision_id": decisionId,
    "stop_id": stopId, "worker_status": (if hadWorker: "joined" else: "no_active_call"),
    "attempts": attempts}), deadline)

proc acknowledgeJoinedEvidence(socket: NativeWebSocket, decisionId, stopId: JsonNode,
    hadWorker: bool, deadline: MonoTime): bool =
  let sent = sendJoinedEvidence(socket, decisionId, stopId, hadWorker, deadline)
  if sent.kind != wsReady: return false
  while getMonoTime() < deadline:
    let received = socket.receiveCleanupMessage(deadline)
    if received.kind != wsMessage: return false
    if received.messageKind.get() == wsmBinary: continue
    let frame = parseJson(received.data)
    if frame["type"].getStr() == "evidence_received" and
        frame["decision_id"] == decisionId and frame["stop_id"] == stopId:
      return true
  false

proc stopAndAcknowledge(socket: NativeWebSocket, decisionId, stopId: JsonNode,
    deadline: MonoTime): bool =
  requestNativeStop()
  let hadWorker = workerCreated
  joinWorker(true)
  acknowledgeJoinedEvidence(socket, decisionId, stopId, hadWorker, deadline)

when isMainModule:
  block playerRun:
    installNativeStopHandlers()
    let url = getEnv("COWORLD_PLAYER_WS_URL")
    if url.len == 0:
      quit("COWORLD_PLAYER_WS_URL is not set", 1)
    let
      prompt = getEnv("PLAYER_PROMPT").strip()
      scriptedEnv = getEnv("PLAYER_SCRIPTED").strip().toLowerAscii()
      label = getEnv("PLAYER_POLICY_LABEL").strip()
    var scripted = ""
    if prompt.len == 0:
      scripted = if scriptedEnv in ["formation", "swarm"]: scriptedEnv
                 else: "formation"
    let kind = if prompt.len > 0: "prompt" else: "scripted"

    let registration = $ %*{
      "type": "register",
      "kind": kind,
      "prompt": prompt,
      "scripted": (if scripted.len > 0: %scripted else: newJNull()),
      "policy": (
        if label.len > 0: label
        elif prompt.len > 0: "prompt"
        else: scripted)
    }

    echo "cogball player: connecting (",
      (if prompt.len > 0: "prompt, " & $prompt.len & " chars"
       else: "scripted " & scripted), ")"
    let timeoutSeconds = parseFloat(getEnv("COWORLD_TIMEOUT_SECONDS", "720"))
    if classify(timeoutSeconds) in {fcNan, fcInf, fcNegInf} or timeoutSeconds <= 0:
      raise newException(ValueError, "positive finite player lifetime is required")
    let lifetimeDeadline = getMonoTime() + initDuration(
      milliseconds = int64(timeoutSeconds * 1000))
    let connection = connectWithRetry(url, min(lifetimeDeadline,
      getMonoTime() + initDuration(milliseconds = ConnectTimeoutMs)))
    if connection.kind in {wsDeadline, wsInterrupted}:
      break playerRun
    if connection.kind != wsReady:
      raise newException(CogballError, "native player connection failed")
    var socket = connection.socket
    defer: closeNativeWebSocket(socket)
    let registrationSent = socket.sendNativeBinary(chatPacket(registration), lifetimeDeadline)
    if registrationSent.kind in {wsDeadline, wsInterrupted, wsClosed}:
      break playerRun
    if registrationSent.kind != wsReady:
      raise newException(CogballError, "native registration send failed")

    var decisionId = newJNull()
    var pendingReceiptId = newJNull()
    var pendingCall = none(tuple[decision: string, deadline: MonoTime])
    var cleanupBudgetMs = 0
    var cleanupStarted = false
    var cleanupDeadline: MonoTime
    var acknowledged = false
    var silenceDeadline = getMonoTime() + initDuration(milliseconds = ReceiveTimeoutMs)
    try:
      while getMonoTime() < min(lifetimeDeadline, silenceDeadline):
        if workerCreated and workerFinished.load(): joinWorker(false)
        if interruptionRequested():
          cleanupDeadline = getMonoTime() + initDuration(milliseconds = cleanupBudgetMs)
          cleanupStarted = true
          acknowledged = stopAndAcknowledge(socket, decisionId, newJNull(), cleanupDeadline)
          break
        let received = socket.receiveNativeMessage(min(min(lifetimeDeadline, silenceDeadline),
          getMonoTime() + initDuration(milliseconds = 50)))
        if received.kind in {wsDeadline, wsInterrupted}: continue
        if received.kind == wsClosed: break
        if received.kind != wsMessage:
          raise newException(CogballError, "native player frame receive failed")
        silenceDeadline = getMonoTime() + initDuration(milliseconds = ReceiveTimeoutMs)
        if received.messageKind.get() == wsmBinary:
          let ready = socket.sendNativeBinary(readyPacket(), lifetimeDeadline)
          if ready.kind in {wsDeadline, wsInterrupted, wsClosed}: break
          if ready.kind != wsReady:
            raise newException(CogballError, "native ready send failed")
          continue
        let decision = parseJson(received.data)
        case decision["type"].getStr()
        of "decision":
          let issuedId = decision["decision_id"]
          if issuedId.kind != JString or issuedId.getStr().len == 0:
            raise newException(CogballError, "nonempty decision identity required")
          let receivedAt = getMonoTime()
          let budget = decision["transport"]["budget_ms"].getInt()
          cleanupBudgetMs = decision["transport"]["cleanup_budget_ms"].getInt()
          if budget <= 0 or cleanupBudgetMs < 0 or
              decision["transport"]["max_output_tokens"].kind != JInt or
              decision["transport"]["max_output_tokens"].getInt() <= 0:
            raise newException(CogballError, "invalid issued transport budget")
          let callDeadline = min(lifetimeDeadline,
            receivedAt + initDuration(milliseconds = budget))
          let hadWorker = workerCreated
          joinWorker(true)
          if interruptionRequested(): break
          let previousId = decisionId
          decisionId = issuedId
          if previousId.kind == JString:
            let sent = sendJoinedEvidence(socket, previousId, newJNull(), hadWorker, callDeadline)
            if sent.kind != wsReady: break
            pendingReceiptId = previousId
            pendingCall = some((decision: $decision, deadline: callDeadline))
          else:
            withLock evidenceLock: workerEvidence.setLen(0)
            startDecisionWorker(socket, $decision, callDeadline)
        of "stop":
          let budget = decision["cleanup_budget_ms"].getInt()
          if budget < 0: raise newException(CogballError, "negative cleanup budget")
          cleanupDeadline = getMonoTime() + initDuration(milliseconds = budget)
          cleanupStarted = true
          acknowledged = stopAndAcknowledge(socket, decisionId, decision["stop_id"], cleanupDeadline)
          break
        of "final": break
        of "evidence_received":
          if pendingCall.isSome and decision["decision_id"] == pendingReceiptId and
              decision["stop_id"].kind == JNull:
            let call = pendingCall.get()
            pendingCall = none(tuple[decision: string, deadline: MonoTime])
            pendingReceiptId = newJNull()
            if not interruptionRequested() and getMonoTime() < call.deadline:
              withLock evidenceLock: workerEvidence.setLen(0)
              startDecisionWorker(socket, call.decision, call.deadline)
        else: raise newException(CogballError, "unexpected private player frame")
    finally:
      if not acknowledged and not cleanupStarted and cleanupBudgetMs > 0:
        cleanupDeadline = getMonoTime() + initDuration(milliseconds = cleanupBudgetMs)
        discard stopAndAcknowledge(socket, decisionId, newJNull(), cleanupDeadline)
      joinWorker(true)
