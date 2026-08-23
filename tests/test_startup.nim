## Startup contract: the entrypoint dies with a clean message and no traceback
## on a bad config, the seed is randomised when unpinned and honoured when
## pinned, and both entrypoints exist in the image.

import std/[os, strutils]
import lib/helpers
import cogball/sim_config

proc badConfigIsRejectedCleanly() =
  ## `config.update` raises a CogballError with a readable message; the
  ## entrypoint turns that into `quit(msg, 1)`, never a traceback.
  var config = defaultGameConfig()
  var message = ""
  try:
    config.update("this is not json")
  except CogballError as error:
    message = error.msg
  doAssert message.contains("not valid JSON"),
    "an unparseable config did not say so: " & message
  message = ""
  try:
    var other = defaultGameConfig()
    other.update("[1,2,3]")
  except CogballError as error:
    message = error.msg
  doAssert message.contains("must be a JSON object"), message
  message = ""
  try:
    var other = defaultGameConfig()
    other.update("""{"num_agents": 6}""")
  except CogballError as error:
    message = error.msg
  doAssert message.contains("num_agents must be 2"), message
  message = ""
  try:
    var other = defaultGameConfig()
    other.update("""{"maxTicks": 0}""")
  except CogballError as error:
    message = error.msg
  doAssert message.contains("maxTicks"), message
  message = ""
  try:
    var other = defaultGameConfig()
    other.update("""{"turnBudgetMs": 100}""")
  except CogballError as error:
    message = error.msg
  doAssert message.contains("turnBudgetMs"), message
  # The entrypoint's own handling: a clean message, exit 1, no traceback.
  let source = readFile("src/cogball.nim")
  doAssert source.contains("quit(\"cogball: bad config: \" & error.msg, 1)"),
    "the entrypoint no longer turns a bad config into a clean exit"
  report "a bad config is rejected with a clean message and exit 1"

proc seedIsPinnedOrRandomised() =
  ## The compiled-in default doubles as the "nobody chose a seed" sentinel, and
  ## it is deliberately NOT the certification fixture's seed.
  doAssert DefaultSeed != 679961,
    "the default seed collides with the certification fixture's pin"
  let source = readFile("src/cogball.nim")
  doAssert source.contains("const LegacyFixedSeed = DefaultSeed")
  doAssert source.contains("config.seed = randomSeed()")
  doAssert source.contains("stripUnpinnedSeed"),
    "an unpinned sentinel seed could clobber the randomised one"
  # A pinned seed is honoured end to end.
  var config = defaultGameConfig()
  config.update("""{"seed": 424242}""")
  doAssert config.seed == 424242
  var sim = initSimServer(config)
  doAssert sim.config.seed == 424242
  # ...and it determines the kickoff.
  var a = seatedSim(testConfig(seed = 4))
  var b = seatedSim(testConfig(seed = 4))
  a.startGame()
  b.startGame()
  for i in 0 ..< RobotCount:
    doAssert a.robots[i].y == b.robots[i].y
  var c = seatedSim(testConfig(seed = 5))
  c.startGame()
  var different = false
  for i in 0 ..< RobotCount:
    if c.robots[i].y != a.robots[i].y:
      different = true
  doAssert different, "two different seeds produced the same kickoff"
  report "the seed is randomised when unpinned and honoured when pinned"

proc bothEntrypointsAreDeclared() =
  ## The docker smoke asserts they EXIST in the image; here we assert the repo
  ## still declares both and that they come out of one image.
  doAssert fileExists("src/cogball.nim")
  doAssert fileExists("src/cogball_player.nim")
  let dockerfile = readFile("Dockerfile")
  doAssert dockerfile.contains("--out:cogball src/cogball.nim")
  doAssert dockerfile.contains("--out:cogball-player src/cogball_player.nim")
  doAssert dockerfile.contains("COPY --from=build /workspace/cogball/cogball /bin/cogball")
  doAssert dockerfile.contains("/bin/cogball-player")
  doAssert dockerfile.contains("COPY --from=build /workspace/cogball/data ./data"),
    "the runtime stage does not ship data/ — the rig art would be missing"
  doAssert dockerfile.contains("CMD [\"/bin/cogball\"]")
  let player = readFile("src/cogball_player.nim")
  doAssert player.contains("COWORLD_PLAYER_WS_URL")
  doAssert player.contains("PLAYER_PROMPT")
  doAssert player.contains("PLAYER_SCRIPTED")
  doAssert player.contains("PLAYER_POLICY_LABEL")
  report "one image declares both entrypoints and ships the art"

proc theRuntimeContractIsRead() =
  let source = readFile("src/cogball/server.nim")
  for name in ["COGAME_EVENTS_URI", "COGAME_PLAYER_FAILURE_URI"]:
    doAssert source.contains(name), "the server no longer reads " & name
  let entry = readFile("src/cogball.nim")
  doAssert entry.contains("readRuntimeConfig()"),
    "the entrypoint no longer reads the COGAME_* runtime contract"
  report "the COGAME_* runtime contract is read at startup"

proc missingConfigUriIsSurvivable() =
  ## No COGAME_CONFIG_URI at all is the DEFAULT config, not a crash: the smoke
  ## and the certifier both rely on that.
  var config = defaultGameConfig()
  config.update("")
  doAssert config.numAgents == 2
  doAssert config.maxTicks == DefaultMaxTicks
  report "an absent config falls back to the defaults, cleanly"

when isMainModule:
  echo "test_startup"
  badConfigIsRejectedCleanly()
  seedIsPinnedOrRandomised()
  bothEntrypointsAreDeclared()
  theRuntimeContractIsRead()
  missingConfigUriIsSurvivable()
  echo "test_startup: all good"
