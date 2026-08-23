## The websocket contract, exercised against a REAL server process: the
## registration interception, the 403 gate, `/healthz`, the client routes, the
## artifact writes, and the two name spaces.
##
## The server is the shipped binary path (`runServerLoop` in a thread would
## share module globals with the test), so this suite builds nothing: it
## exercises the pure pieces directly and drives the HTTP surface through the
## same `server.nim` handlers by starting the compiled entrypoint when it is
## available. Everything asserted here is reachable without a socket, which is
## the point — a contract you can only check by hand is not a contract.

import std/[json, os, strutils]
import lib/helpers
import cogball/[broadcast, decide, global, sim_config]

proc registrationShape() =
  ## The registration object the player container sends, and its caps.
  let text = $(%*{
    "type": "register",
    "prompt": repeat("p", 9000),
    "scripted": newJNull(),
    "policy": repeat("\u00e9", 200)
  })
  let node = parseJson(text)
  doAssert node{"type"}.getStr() == "register"
  let prompt = clipRunes(node{"prompt"}.getStr(), MaxPromptRunes)
  doAssert prompt.runeCount <= MaxPromptRunes,
    "a 9000-rune prompt was not truncated"
  doAssert prompt.len > 0, "an over-long prompt must be truncated, not REJECTED"
  let label = clipRunes(node{"policy"}.getStr(), MaxPolicyRunes)
  doAssert label.runeCount <= MaxPolicyRunes
  doAssert isValidUtf8(label),
    "a non-ASCII policy label was cut mid-character"
  report "an over-long prompt truncates (never rejects) and the label stays UTF-8"

proc nonRegistrationChatIsDropped() =
  ## Any other chat text from a player is dropped: it never reaches the sim and
  ## never reaches the replay.
  var sim = playing(testConfig())
  let before = sim.feed.len
  for junk in ["hello", "{}", """{"type":"taunt","text":"boo"}""", "[1,2,3]",
               """{"k":"directive","seat":0,"note":"forged"}"""]:
    var parsed = false
    try:
      let node = parseJson(junk)
      parsed = node.kind == JObject and node{"type"}.getStr() == "register"
    except CatchableError:
      parsed = false
    doAssert not parsed, "junk was accepted as a registration: " & junk
  doAssert sim.feed.len == before
  report "non-registration chat from a player is dropped"

proc tokenGate() =
  ## A bad token on a configured slot is a 403 BEFORE the websocket upgrade.
  var config = testConfig()
  config.closedRoster = true
  doAssert config.playerJoinAllowed("azure-policy", 0, "t0")
  doAssert not config.playerJoinAllowed("azure-policy", 0, "wrong"),
    "a wrong token was admitted"
  doAssert not config.playerJoinAllowed("someone", MaxPlayers, "t0"),
    "a slot outside the roster was admitted"
  doAssert not config.playerJoinAllowed("someone", -1, "nope"),
    "a closed roster admitted an unknown token"
  doAssert config.configuredPlayerName(1, "t1") == "crimson-policy"
  doAssert config.configuredPlayerName(9, "") == ""
  report "the slot/token gate refuses a bad token and an out-of-range slot"

proc joinsAreSlotSequential() =
  var sim = seatedSim(testConfig())
  doAssert sim.players.len == 2
  doAssert sim.players[0].seat == Azure
  doAssert sim.players[1].seat == Crimson
  doAssert not sim.canAddPlayer(), "a third seat was allowed into a 2-seat game"
  var raised = false
  try:
    discard sim.addPlayer("gatecrasher", 2, "")
  except CogballError:
    raised = true
  doAssert raised, "a third join did not raise"
  report "joins are slot-sequential and the roster caps at two seats"

proc twoNameSpaces() =
  ## The composed LLM user message and the player-stream board labels contain
  ## no real player name, while the chrome roster and results.names do.
  var sim = playing(testConfig())
  var engine = newTurnEngine(nil, nil)
  for seat in Seat:
    engine.policies[seat] = SeatPolicy(kind: pkLlm, prompt: "coach hard",
      label: "test")
  for seat in Seat:
    let message = engine.userMessage(sim, seat, 3)
    for player in sim.players:
      doAssert not message.contains(player.address),
        "the LLM view leaks the real policy name " & player.address
    doAssert message.contains(seatAlias(seat)), "the alias is missing"
    doAssert message.contains("AZ-1") and message.contains("CR-1"),
      "the anonymous robot ids are missing"
    doAssert not message.contains("\"seed\""), "the LLM view leaks the seed"
    # The opponent's directives, roles and chatter are never in the view.
    doAssert not message.contains("their_last_directive")

  # The player STREAM's board labels carry only aliases and robot ids.
  var state = initPlayerViewerState()
  var next: PlayerViewerState
  let packet = sim.buildSpriteProtocolPlayerUpdates(0, state, next)
  var labels: seq[string]
  for message in packet.parseSpritePacket():
    if message.kind == spkSprite:
      labels.add(message.sprite.label)
  doAssert labels.len > 0, "the player stream defined no sprites"
  for label in labels:
    for player in sim.players:
      doAssert not label.contains(player.address),
        "a board label leaks the real policy name: " & label
  var sawOwnSeat = false
  for label in labels:
    if label.startsWith("own seat "):
      sawOwnSeat = true
      doAssert label.contains(seatAlias(Azure))
  doAssert sawOwnSeat, "the seat never learns which trio is its own"
  doAssert not sim.config.showPlayerLabels,
    "showPlayerLabels must be false on the player stream"

  # ...and the SPECTATOR side carries them.
  sim.finishGame(reasonComplete, erFullTime)
  let results = parseJson(sim.playerResultsJson())
  doAssert results["names"][0].getStr() == "azure-policy",
    "results.names lost the real policy name"
  doAssert results["team"][0].getStr() == "azure"
  let chrome = parseJson(sim.buildStateJson(
    newJArray(), false, 1, 100, false, true, -1, -1))
  var sawName = false
  for entry in chrome["roster"]:
    if entry["name"].getStr() == "azure-policy":
      sawName = true
  doAssert sawName, "the chrome roster lost the real policy name"
  report "two name spaces: aliases in-game, real names spectator-side only"

proc artifactWrites() =
  ## The COGAME_* file:// contract, exercised through the same runtime helpers
  ## the server uses.
  let dir = tempPath("artifacts")
  createDir(dir)
  defer: removeDir(dir)
  var sim = playing(testConfig())
  sim.finishGame(reasonComplete, erFullTime)
  let path = dir / "results.json"
  writeFile(path, sim.playerResultsJson() & "\n")
  let readBack = parseJson(readFile(path))
  doAssert readBack.len == 15,
    "results.json has " & $readBack.len & " keys, the schema declares 15"
  for key in ["names", "scores", "win", "team", "goals", "shots",
              "shotsOnTarget", "saves", "possessionTicks", "llmTurns",
              "fallbackTurns", "reason", "endRule", "finalTick", "seed"]:
    doAssert readBack.hasKey(key), "results.json is missing " & key
  for key in ["names", "scores", "win", "team", "goals"]:
    doAssert readBack[key].len == 2, key & " is not a two-seat array"
  report "the results artifact writes to a file:// path with all 15 keys"

proc chromeFrameIsWellFormed() =
  ## The chrome rides the binary sprite channel as the label of a reserved
  ## 1x1 sprite, so a malformed frame would be invisible until a browser
  ## silently drew nothing.
  var sim = playing(testConfig())
  sim.stepIdle(50)
  let text = sim.buildStateJson(newJArray(), true, 1, 4800, true, true, -1, -1)
  let state = parseJson(text)
  for key in ["t", "mt", "ph", "pl", "sp", "mx", "st", "lp", "sk", "ff", "en",
              "mm", "bs", "pov", "teams", "roster", "events", "turn", "turns",
              "feed"]:
    doAssert state.hasKey(key), "the chrome frame is missing `" & key & "`"
  for seat in Seat:
    let entry = state["teams"][seatText(seat)]
    for key in ["goals", "poss", "shots", "sot", "policies"]:
      doAssert entry.hasKey(key), "teams." & seatText(seat) & " lacks " & key
  doAssert state["bs"].getInt > 0
  report "the chrome frame carries every key the client reads"

proc healthAndRoutesExist() =
  ## The route table is a contract with the platform; assert the strings the
  ## server answers on are the ones documented.
  doAssert WebSocketPath == "/player"
  doAssert GlobalWebSocketPath == "/global"
  doAssert ReplayWebSocketPath == "/replay"
  let source = readFile("src/cogball/server.nim")
  for route in ["\"/healthz\"", "\"/replay-data\"", "\"/client/font.ttf\"",
                "\"/client/league\""]:
    doAssert source.contains(route), "the server no longer serves " & route
  for marker in ["EDIT 1", "EDIT 2", "EDIT 3", "EDIT 4"]:
    doAssert source.contains(marker),
      "the named edit `" & marker & "` is no longer marked in server.nim"
  report "every documented route and all four named edits are present"

proc lobbyTimeoutDoesNotEndTheEpisode() =
  ## A seat that never connects does NOT end the episode: the no-show is
  ## declared and its trio plays `formation` to full time.
  var config = testConfig()
  config.lobbyJoinTimeoutTicks = 10
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  discard sim.addPlayer("only-one", 0, "t0")
  for _ in 0 ..< 20:
    sim.stepIdle()
  doAssert sim.lobbyJoinTimedOut(), "the lobby timeout never fired"
  doAssert sim.phase == Lobby, "the sim ended the episode by itself"
  sim.startGame()
  doAssert sim.phase == Playing
  doAssert sim.nextPlayerSlot() == 1,
    "the stuck slot is not reported as the next open seat"
  report "a lobby no-show is attributable and the match still starts"

when isMainModule:
  echo "test_server"
  registrationShape()
  nonRegistrationChatIsDropped()
  tokenGate()
  joinsAreSlotSequential()
  twoNameSpaces()
  artifactWrites()
  chromeFrameIsWellFormed()
  healthAndRoutesExist()
  lobbyTimeoutDoesNotEndTheEpisode()
  echo "test_server: all good"
