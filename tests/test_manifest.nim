## The manifest is a contract with the platform's certifier, and every clause
## in it has a counterpart in the code. This suite is where the two are held
## together: a manifest edited without the sim (or the reverse) fails here
## rather than in hosted certification.

import std/[json, os, strutils]
import lib/helpers


const ManifestPath = "coworld_manifest_template.json"

let manifest = parseJson(readFile(ManifestPath))

proc seatCountEverywhere() =
  ## `num_agents` is 2 in EVERY variant and in the certification fixture, and
  ## every other seat-count declaration agrees with it.
  doAssert manifest.hasKey("variants")
  doAssert manifest["variants"].len >= 2
  for variant in manifest["variants"]:
    let config = variant["game_config"]
    doAssert config.hasKey("num_agents"),
      "variant " & variant["id"].getStr() & " has no num_agents"
    doAssert config["num_agents"].getInt == SeatCount,
      "variant " & variant["id"].getStr() & " seats " &
        $config["num_agents"].getInt
    doAssert config["players"].len == SeatCount
    doAssert config["slots"].len == SeatCount
    doAssert config["minPlayers"].getInt == SeatCount
  let cert = manifest["certification"]
  doAssert cert["game_config"]["num_agents"].getInt == SeatCount
  doAssert cert["players"].len == SeatCount
  doAssert cert["game_config"]["players"].len == SeatCount
  report "num_agents is " & $SeatCount &
    " in every variant and the cert fixture"

proc budgetIsInsideTheEpisodeTimeout() =
  ## 60 % of the platform's 1200 s episode timeout is the design's ceiling.
  const EpisodeTimeoutSeconds = 1200
  for variant in manifest["variants"]:
    let config = variant["game_config"]
    let budget = config["wallClockBudgetSeconds"].getInt
    doAssert budget * 10 <= EpisodeTimeoutSeconds * 6,
      "variant " & variant["id"].getStr() & " budgets " & $budget &
        " s against a " & $EpisodeTimeoutSeconds & " s timeout"
    # The turn budget has to cover both attempts.
    doAssert config["turnBudgetMs"].getInt >=
      config["attempt1Ms"].getInt + config["retryMs"].getInt
    # And the turns have to fit inside the budget with room for the match.
    let turns = config["maxTicks"].getInt div config["turnTicks"].getInt
    doAssert turns * config["turnBudgetMs"].getInt div 1000 < budget,
      "variant " & variant["id"].getStr() & ": " & $turns &
        " turns cannot fit in " & $budget & " s"
  report "every variant settles well inside 60% of the episode timeout"

proc resultsSchemaMatchesTheCode() =
  ## The schema is `additionalProperties: false`, so a key the code writes and
  ## the schema does not declare is a rejected episode.
  var sim = playing(testConfig())
  sim.finishGame(reasonComplete, erFullTime)
  let produced = parseJson(sim.playerResultsJson())
  let declared = manifest["game"]["results_schema"]["properties"]
  doAssert declared.len == produced.len,
    "the schema declares " & $declared.len & " keys, the code writes " &
      $produced.len
  for key, _ in produced:
    doAssert declared.hasKey(key),
      "playerResultsJson writes `" & key & "`, the schema does not declare it"
  for key, _ in declared:
    doAssert produced.hasKey(key),
      "the schema declares `" & key & "`, playerResultsJson never writes it"
  doAssert manifest["game"]["results_schema"]["additionalProperties"].getBool ==
    false
  for key in ["names", "scores", "win", "team", "goals", "reason", "endRule"]:
    var required = false
    for entry in manifest["game"]["results_schema"]["required"]:
      if entry.getStr() == key:
        required = true
    doAssert required, key & " must be required"
  let reasons = manifest["game"]["results_schema"]["properties"]["reason"]["enum"]
  doAssert reasons.len == 3
  for reason in EndReason:
    var present = false
    for entry in reasons:
      if entry.getStr() == reasonText(reason):
        present = true
    doAssert present, "the reason enum is missing " & reasonText(reason)
  let rules = manifest["game"]["results_schema"]["properties"]["endRule"]["enum"]
  for rule in EndRule:
    var present = false
    for entry in rules:
      if entry.getStr() == endRuleText(rule):
        present = true
    doAssert present, "the endRule enum is missing " & endRuleText(rule)
  for key, spec in declared:
    if spec.hasKey("items"):
      doAssert spec["minItems"].getInt == 2 and spec["maxItems"].getInt == 2,
        key & " is not pinned to two seats"
  report "results_schema matches playerResultsJson key for key"

proc configSchemaCoversWhatTheCodeReads() =
  ## Every field `sim_config.update` reads must be declared, or a variant that
  ## sets it is rejected by the certifier.
  let declared = manifest["game"]["config_schema"]["properties"]
  let source = readFile("src/cogball/sim_config.nim")
  var missing: seq[string]
  for line in source.splitLines():
    let trimmed = line.strip()
    for reader in ["node.readInt(\"", "node.readBool(\"", "node.readStr(\""]:
      if trimmed.startsWith(reader):
        let rest = trimmed[reader.len .. ^1]
        let key = rest[0 ..< rest.find('"')]
        if not declared.hasKey(key) and key notin ["numAgents"]:
          missing.add(key)
  doAssert missing.len == 0,
    "config_schema does not declare: " & missing.join(", ")
  for key in ["tokens", "players", "slots"]:
    doAssert declared.hasKey(key), "config_schema lacks " & key
  doAssert manifest["game"]["config_schema"]["additionalProperties"].getBool ==
    false
  var required: seq[string]
  for entry in manifest["game"]["config_schema"]["required"]:
    required.add(entry.getStr())
  doAssert required == @["tokens", "players"]
  report "config_schema covers every field sim_config.update reads"

proc viewerIsAStaticBundle() =
  doAssert manifest["game"]["replay_viewer"]["bundle"].getStr() ==
    "static-replay-viewer",
    "the replay viewer must be the STATIC bundle, never a pod"
  report "replay_viewer.bundle is static-replay-viewer"

proc protocolsAndDocs() =
  let protocols = manifest["game"]["protocols"]
  for side in ["player", "global"]:
    doAssert protocols.hasKey(side), "game.protocols lacks " & side
    doAssert protocols[side]["value"].getStr().len > 0
  let docs = manifest["game"]["docs"]
  doAssert docs["readme"]["type"].getStr() == "text",
    "game.docs.readme must be inline TEXT, not a URI"
  doAssert docs["readme"]["value"].getStr().len > 1000,
    "the inlined readme is suspiciously short"
  doAssert docs["pages"].len == 3
  var ids: seq[string]
  for page in docs["pages"]:
    ids.add(page["id"].getStr())
    doAssert page["title"].getStr().len > 0
    doAssert page["content"]["type"].getStr() == "text"
    doAssert page["content"]["value"].getStr().len > 1000,
      "page " & page["id"].getStr() & " is suspiciously short"
  doAssert ids == @["rules.md", "protocol.md", "coaching.md"], $ids
  # And the inlined text is the CURRENT docs, not a stale paste.
  doAssert docs["readme"]["value"].getStr() == readFile("README.md")
  doAssert docs["pages"][0]["content"]["value"].getStr() ==
    readFile("docs/RULES.md")
  doAssert docs["pages"][1]["content"]["value"].getStr() ==
    readFile("docs/PROTOCOL.md")
  doAssert docs["pages"][2]["content"]["value"].getStr() ==
    readFile("docs/COACHING.md")
  report "both protocols are declared and all four docs are inline, current text"

proc imageAndEntrypoints() =
  let compose = readFile("compose.yaml")
  doAssert compose.contains("image: coworld-cogball:latest")
  doAssert compose.contains("platform: linux/amd64")
  doAssert compose.contains("network: host")
  doAssert compose.contains("cogball:"), "the compose SERVICE is not named for the coworld"
  doAssert manifest["game"]["runnable"]["image"].getStr() == "{{COGBALL_IMAGE}}",
    "the manifest placeholder does not match the compose service name"
  doAssert manifest["game"]["runnable"]["run"][0].getStr() == "/bin/cogball"
  doAssert manifest["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"]
    .getStr() == "secret://coworld/cogball/anthropic_api_key"
  doAssert manifest["player"][0]["image"].getStr() == "{{COGBALL_IMAGE}}",
    "the bundled player must come out of the SAME image"
  doAssert manifest["player"][0]["run"][0].getStr() == "/bin/cogball-player"
  doAssert manifest["player"][0]["env"]["PLAYER_SCRIPTED"].getStr() ==
    "formation", "the certification player must be the scripted baseline"
  let dockerfile = readFile("Dockerfile")
  doAssert dockerfile.contains("/bin/cogball") and
    dockerfile.contains("/bin/cogball-player"),
    "the image does not ship both entrypoints"
  report "one image, two entrypoints, and the placeholder matches compose"

proc policiesAreTheRightShape() =
  ## Two LLM prompt policies and two scripted baselines, all env-switched out
  ## of one image, with champion #2 owned by the second identity.
  let policies = parseJson(readFile("tools/ci/policies.json"))
  doAssert policies.len == 4, "expected four policies, saw " & $policies.len
  var prompts = 0
  var scripted = 0
  var owned = 0
  var names: seq[string]
  for policy in policies:
    names.add(policy["name"].getStr())
    doAssert policy["run"].getStr() == "/bin/cogball-player",
      "every policy runs the one player entrypoint"
    if policy["env"].hasKey("PLAYER_PROMPT"):
      inc prompts
      doAssert policy["env"]["PLAYER_PROMPT"].getStr().len > 300,
        policy["name"].getStr() & "'s prompt is too thin to be a strategy"
    if policy["env"].hasKey("PLAYER_SCRIPTED"):
      inc scripted
      doAssert policy["env"]["PLAYER_SCRIPTED"].getStr() in
        ["formation", "swarm"]
    if policy.hasKey("player"):
      inc owned
      doAssert policy["player"].getStr().startsWith("ply_")
  doAssert prompts == 2, "expected two LLM champions"
  doAssert scripted == 2, "expected two scripted fillers"
  doAssert owned == 1, "champion #2 must carry its owning player id"
  doAssert names == @["cogball-total", "cogball-counter", "cogball-formation",
    "cogball-swarm"], $names
  # The two champion prompts must actually differ.
  doAssert policies[0]["env"]["PLAYER_PROMPT"].getStr() !=
    policies[1]["env"]["PLAYER_PROMPT"].getStr()
  report "policies.json: two prompts, two baselines, one image, owner pinned"

proc scaffoldIsExecutable() =
  for path in ["tools/ci/docker_smoke.sh", "tools/build_replay_viewer.sh"]:
    doAssert fileExists(path), path & " is missing"
    let permissions = getFilePermissions(path)
    doAssert fpUserExec in permissions,
      path & " must be committed executable (mode 100755)"
  for path in [".github/workflows/ci.yml",
               ".github/workflows/coworld-release.yml",
               ".github/workflows/coworld-submit.yml",
               "tools/ci/policies.json"]:
    doAssert fileExists(path), path & " is missing"
  report "the CI scaffold is present and both hooks are executable"

proc noUnsubstitutedPlaceholders() =
  ## The three scaffold placeholders, and only those three. The four
  ## angle-bracket names that survive by design are runtime values.
  const Expected = ["<run_id>", "<name>", "<cow_id>", "<sha>"]
  for path in [".github/workflows/ci.yml",
               ".github/workflows/coworld-release.yml",
               ".github/workflows/coworld-submit.yml",
               "tools/ci/docker_smoke.sh", "tools/ci/policies.json"]:
    let text = readFile(path)
    for placeholder in ["<slug>", "<IMAGE>", "<SEATS>"]:
      doAssert not text.contains(placeholder),
        path & " still carries " & placeholder
    var i = 0
    while i < text.len:
      let open = text.find('<', i)
      if open < 0:
        break
      let close = text.find('>', open)
      if close < 0 or close - open > 12:
        i = open + 1
        continue
      let token = text[open .. close]
      var ok = true
      for ch in token[1 ..< token.len - 1]:
        if ch notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}:
          ok = false
      if ok and token notin Expected:
        doAssert false, path & " carries an unexpected placeholder " & token
      i = open + 1
  report "no unsubstituted placeholder survives in the scaffold"

when isMainModule:
  echo "test_manifest"
  seatCountEverywhere()
  budgetIsInsideTheEpisodeTimeout()
  resultsSchemaMatchesTheCode()
  configSchemaCoversWhatTheCodeReads()
  viewerIsAStaticBundle()
  protocolsAndDocs()
  imageAndEntrypoints()
  policiesAreTheRightShape()
  scaffoldIsExecutable()
  noUnsubstitutedPlaceholders()
  echo "test_manifest: all good"
