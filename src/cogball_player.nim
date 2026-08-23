## Cogball player: a policy is just a prompt.
##
## Connects to the game, delivers its registration in ONE Sprite v1 chat
## message, then idles until the socket closes. Every decision happens inside
## the game server, which sends this seat's prompt to Claude once every five
## seconds of match time; a deterministic control layer turns the reply into
## the six robots' actuator masks.
##
##   PLAYER_PROMPT=<strategy text>     -> an LLM seat
##   PLAYER_SCRIPTED=formation|swarm   -> a scripted seat
##   (neither)                         -> PLAYER_SCRIPTED=formation
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <cogball-image> --name my-cogball \
##     --run /bin/cogball-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, monotimes, net, options, os, strutils, times],
  whisky

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

  let registration = $ %*{
    "type": "register",
    "prompt": prompt,
    "scripted": (if scripted.len > 0: %scripted else: newJNull()),
    "policy": (
      if label.len > 0: label
      elif prompt.len > 0: "llm"
      else: scripted)
  }

  echo "cogball player: connecting (",
    (if prompt.len > 0: "prompt, " & $prompt.len & " chars"
     else: "scripted " & scripted), ")"
  let socket = connectWithRetry(url)
  socket.send(chatPacket(registration), BinaryMessage)

  var reRegistered = false
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
    if not reRegistered:
      # Re-sent once after the first received frame, in case the first send
      # raced the server's slot registration (babel's pattern).
      reRegistered = true
      socket.send(chatPacket(registration), BinaryMessage)
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
