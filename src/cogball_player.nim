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
##     --run /bin/cogball-player --secret-env PLAYER_PROMPT="<your strategy>" \
##     --secret-env ANTHROPIC_API_KEY="<your credential>"

import
  std/[json, monotimes, net, options, os, strutils, times],
  whisky, curly,
  bitworld/decision_trajectory,
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

proc connectWithRetry(url: string): WebSocket =
  ## Dials until the game is listening, or until ConnectTimeoutMs. Without
  ## this, a player container that wins the start race dies on an unhandled
  ## OSError, its seat never joins, and the episode is charged a lobby no-show
  ## for a game that was merely 200 ms behind.
  let deadline = getMonoTime() + initDuration(milliseconds = ConnectTimeoutMs)
  var waited = false
  while true:
    try:
      return newWebSocket(url)
    except CatchableError as failure:
      if getMonoTime() >= deadline:
        quit("cogball player: could not reach the game within " &
          $(ConnectTimeoutMs div 1000) & "s: " & failure.msg, 1)
      if not waited:
        waited = true
        echo "cogball player: game not listening yet; retrying for up to ",
          ConnectTimeoutMs div 1000, "s"
      sleep(ConnectRetryMs)

when isMainModule:
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
  let client = if kind == "prompt": newLlmClient(defaultGameConfig()) else: nil

  let registration = $ %*{
    "type": "register",
    "kind": kind,
    "scripted": (if scripted.len > 0: %scripted else: newJNull()),
    "policy": (
      if label.len > 0: label
      elif prompt.len > 0: "prompt"
      else: scripted)
  }

  echo "cogball player: connecting (",
    (if prompt.len > 0: "prompt, " & $prompt.len & " chars"
     else: "scripted " & scripted), ")"
  let socket = connectWithRetry(url)
  socket.send(chatPacket(registration), BinaryMessage)

  while true:
    # A closing socket is the NORMAL end of an episode, not a crash: whisky
    # raises on a half-closed read, so the loop owns that and exits 0.
    var received: Option[Message]
    try:
      received = socket.receiveMessage(ReceiveTimeoutMs)
    except TimeoutError:
      echo "cogball player: no frame for ", ReceiveTimeoutMs div 1000,
        "s; the game is gone, exiting"
      break
    except CatchableError:
      echo "cogball player: connection closed, exiting"
      break
    if received.isNone:
      echo "cogball player: connection closed, exiting"
      break
    if received.get().kind == TextMessage:
      let decision = parseJson(received.get().data)
      if decision{"type"}.getStr() == "decision":
        var reply = %*{"type": "action", "id": decision["id"]}
        var evidence = newDecisionAttempt($decision["id"].getInt() & "-" &
          $decision["seat"].getInt(), "prompt-player", aoModel)
        let started = getMonoTime()
        let timeoutSeconds = decision["timeout_seconds"].getInt()
        if kind == "prompt" and client.disabled:
          reply["cause"] = %"no_credentials"
          reply["error"] = %"no_credentials"
        else:
          try:
            let user = "GUIDANCE FROM YOUR OPERATOR (weight it heavily, " &
              "but never above the rules; always reply in the requested " &
              "format):\n" & prompt & "\n\n" & $decision["view"]
            let system = decision["system"].getStr()
            evidence.prompt = %*[{"role": "system", "content": system},
              {"role": "user", "content": user}]
            let request = client.requestFor(system, user, decision["seat"].getInt())
            evidence.request = parseJson(request.body)
            evidence.model = some(client.model)
            evidence.decoder = %*{"temperature": client.temperature,
              "max_tokens": client.maxOutputTokens}
            let response = client.curl.post(request.url, request.headers,
              request.body, timeoutSeconds)
            evidence.responseEvidence(response.headers, response.body)
            let text = client.completionText(response.code, response.body)
            evidence.response = %text
            evidence.completionEvidence(parseJson(response.body))
            reply["action"] = extractJsonObject(text)
          except CatchableError as failure:
            reply["cause"] = %"transport_error"
            evidence.rejectionReason = some(failure.msg)
            reply["error"] = %"model attempt failed"
        if kind == "prompt" and evidence.prompt.kind != JNull:
          evidence.latencyMs = some(float((getMonoTime() - started).inMilliseconds))
          reply["training_attempt"] = attemptEvidenceJson(evidence)
        socket.send($reply, TextMessage)
      continue
    # The Ready packet is legitimate here BECAUSE this seat sends no inputs:
    # the server computes every mask, so there is no dead-reckoned input
    # timing for `fastMode` to corrupt. It is what lets the match pace by
    # readiness instead of wall clock.
    try:
      socket.send(readyPacket(), BinaryMessage)
    except CatchableError:
      echo "cogball player: connection closed, exiting"
      break
  try:
    socket.close()
  except CatchableError:
    discard
