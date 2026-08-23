## Tolerant parsing and repair, and the rune-boundary truncation rule.
##
## A byte-truncated multi-byte character is exactly the bug that makes replay
## bytes render in a browser but fail a strict parser, so the emoji case here
## is not decoration: it is the assertion the whole rune discipline exists for.

import std/[json, strutils, unicode]
import lib/helpers
import cogball/llm

proc parseOf(
  sim: SimServer,
  seat: Seat,
  text: string,
  hasPrevious = false
): tuple[directive: Directive, usable: bool] =
  let payload = extractJsonObject(text)
  parseDirective(sim, seat, payload, sim.formationDirective(seat, 0),
    hasPrevious, sim.formationDirective(seat, 0), 1)

proc prosePrefixed() =
  var sim = playing(testConfig())
  let text = """Sure! Here is my plan for this turn.

```json
{"note":"press high","robots":[
 {"id":"AZ-1","role":"keeper","intent":"hold","target":[-17,0],"kick":"auto"},
 {"id":"AZ-2","role":"striker","intent":"shoot","target":[4,1],"kick":"auto"},
 {"id":"AZ-3","role":"wing","intent":"intercept","target":[8,-4],"kick":"auto"}]}
```

Hope that helps!"""
  let got = sim.parseOf(Azure, text)
  doAssert got.usable
  doAssert got.directive.note == "press high"
  doAssert got.directive.robots[0].intent == inHold
  doAssert got.directive.robots[1].intent == inShoot
  doAssert got.directive.robots[2].intent == inIntercept
  doAssert got.directive.robots[0].targetX == worldXOfView(-17.0)
  report "prose-prefixed, fenced JSON parses"

proc objectKeyedRobots() =
  var sim = playing(testConfig())
  let text = """{"note":"","robots":{
    "AZ-3":{"role":"striker","intent":"chase","target":[0,0]},
    "az-1":{"role":"keeper","intent":"hold","target":["-18","1.5"]},
    "AZ-2":{"role":"back","intent":"press","target":[2,2]}}}"""
  let got = sim.parseOf(Azure, text)
  doAssert got.usable
  doAssert got.directive.robots[0].intent == inHold, "AZ-1 (lowercase) misread"
  doAssert got.directive.robots[1].intent == inPress
  doAssert got.directive.robots[2].intent == inChase
  doAssert got.directive.robots[0].targetX == worldXOfView(-18.0),
    "a numeric STRING target was rejected"
  report "an id-keyed robots object with numeric strings parses"

proc unknownEnumsRepair() =
  var sim = playing(testConfig())
  let text = """{"note":"x","robots":[
   {"id":"AZ-1","role":"libero","intent":"nutmeg","kick":"maybe","target":[0,0]},
   {"id":"AZ-2","role":"back","intent":"clear","kick":"never","target":[0,0]},
   {"id":"AZ-3","role":"wing","intent":"pass","pass_to":"CR-1","target":[0,0]}]}"""
  let got = sim.parseOf(Azure, text)
  doAssert got.usable
  doAssert got.directive.robots[0].role == roleWing, "unknown role repaired wrong"
  doAssert got.directive.robots[0].intent == inChase,
    "unknown intent repaired wrong"
  doAssert got.directive.robots[0].kick == kickAuto,
    "unknown kick repaired wrong"
  doAssert got.directive.robots[1].kick == kickNever
  doAssert got.directive.robots[2].passTo == -1,
    "pass_to accepted an OPPONENT"
  report "unknown enums and a cross-team pass_to repair"

proc badTargets() =
  var sim = playing(testConfig())
  sim.robots[0].x = 7_777_777'i32
  sim.robots[0].y = 3_333_333'i32
  let text = """{"note":"x","robots":[
   {"id":"AZ-1","role":"back","intent":"hold"},
   {"id":"AZ-2","role":"back","intent":"hold","target":[999,-999]},
   {"id":"AZ-3","role":"back","intent":"hold","target":["nope","nope"]}]}"""
  let got = sim.parseOf(Azure, text)
  doAssert got.usable
  doAssert got.directive.robots[0].targetX == sim.robots[0].x,
    "a missing target did not fall back to the robot's position"
  doAssert got.directive.robots[0].targetY == sim.robots[0].y
  doAssert got.directive.robots[1].targetX == worldXOfView(20.0),
    "an out-of-pitch target was not clamped"
  doAssert got.directive.robots[1].targetY == worldYOfView(-12.5)
  doAssert got.directive.robots[2].targetX == sim.robots[2].x,
    "a non-numeric target did not fall back"
  report "missing, out-of-pitch and non-numeric targets repair"

proc wrongRobotCounts() =
  var sim = playing(testConfig())
  # Four robots: the extra entry is dropped.
  let four = sim.parseOf(Azure, """{"robots":[
    {"id":"AZ-1","intent":"hold","target":[1,1]},
    {"id":"AZ-2","intent":"shoot","target":[2,2]},
    {"id":"AZ-3","intent":"press","target":[3,3]},
    {"id":"AZ-1","intent":"clear","target":[4,4]}]}""")
  doAssert four.usable
  doAssert four.directive.robots[0].intent == inHold,
    "a duplicate id overwrote the first entry"
  # Zero robots: nothing usable, which is the ONE case that triggers a retry.
  let zero = sim.parseOf(Azure, """{"note":"thinking","robots":[]}""")
  doAssert not zero.usable, "an empty robots array was treated as usable"
  # One robot: usable; the other two come from the fallback.
  let one = sim.parseOf(Azure, """{"robots":[{"id":"AZ-2","intent":"clear"}]}""")
  doAssert one.usable
  doAssert one.directive.robots[1].intent == inClear
  report "four, zero and one robot entries all repair correctly"

proc positionalAssignment() =
  ## Unmatched ids are assigned to the seat's robots BY POSITION, in reply
  ## order — the documented repair for a model that invents names.
  var sim = playing(testConfig())
  let got = sim.parseOf(Crimson, """{"robots":[
    {"id":"striker","intent":"shoot","target":[0,0]},
    {"id":"midfield","intent":"press","target":[0,0]},
    {"id":"sweeper","intent":"hold","target":[0,0]}]}""")
  doAssert got.usable
  doAssert got.directive.robots[0].intent == inShoot
  doAssert got.directive.robots[1].intent == inPress
  doAssert got.directive.robots[2].intent == inHold
  report "unmatched ids are assigned by position"

proc runeTruncation() =
  ## A 300-character note truncates to 160 RUNES, and a `say` whose 48th and
  ## 49th characters are a 4-byte emoji lands on the rune boundary — the
  ## result must still round-trip through `%$` -> parseJson and decode as UTF-8.
  var sim = playing(testConfig())
  let longNote = repeat("n", 300)
  # 47 ASCII characters, then two 4-byte emoji: the cut lands between them.
  let say = repeat("s", 47) & "\u{1F3C6}\u{26BD}"
  doAssert say.runeLen == 49
  let text = $(%*{
    "note": longNote,
    "robots": [
      {"id": "AZ-1", "intent": "hold", "target": [0, 0], "say": say},
      {"id": "AZ-2", "intent": "hold", "target": [0, 0], "say": say},
      {"id": "AZ-3", "intent": "hold", "target": [0, 0], "say": say}
    ]
  })
  let got = sim.parseOf(Azure, text)
  doAssert got.usable
  doAssert got.directive.note.runeLen == MaxNoteRunes,
    "note truncated to " & $got.directive.note.runeLen & " runes"
  doAssert isValidUtf8(got.directive.note)
  let clipped = got.directive.robots[0].say
  doAssert clipped.runeLen == MaxSayRunes,
    "say truncated to " & $clipped.runeLen & " runes"
  doAssert isValidUtf8(clipped),
    "say was cut mid-character: " & $clipped.len & " bytes"
  doAssert clipped.endsWith("\u2026"), "the cut is not marked"
  # The whole point: it must survive a strict round trip.
  let record = directiveJson(sim, Azure, got.directive)
  let roundTripped = parseJson($record)
  doAssert roundTripped["robots"][0]["say"].getStr() == clipped
  doAssert isValidUtf8($record)
  doAssert capRecord($record).runeLen <= MaxDirectiveRecordRunes
  report "note and say truncate on rune boundaries and round-trip strictly"

proc clipRunesIsExact() =
  doAssert clipRunes("", 10) == ""
  doAssert clipRunes("abc", 10) == "abc"
  doAssert clipRunes("abcdef", 3).runeLen == 3
  # Control characters never reach the replay.
  doAssert clipRunes("a\x07b\nc", 10) == "abc"
  # A pure-emoji string truncates on codepoints, not bytes.
  let emoji = repeat("\u{1F3C6}", 20)
  doAssert emoji.len == 80
  let cut = clipRunes(emoji, 5)
  doAssert cut.runeLen == 5
  doAssert isValidUtf8(cut)
  report "clipRunes counts codepoints, strips control characters and marks the cut"

proc noJsonAtAll() =
  var sim = playing(testConfig())
  var raised = false
  try:
    discard sim.parseOf(Azure, "I am not going to answer that.")
  except CatchableError:
    raised = true
  doAssert raised, "a reply with no JSON object was accepted"
  report "a reply with no JSON object is rejected (and retried by the engine)"

proc idParsing() =
  doAssert robotIndexOfId("AZ-1") == 0
  doAssert robotIndexOfId("az-3") == 2
  doAssert robotIndexOfId("CR-1") == 3
  doAssert robotIndexOfId(" cr 2 ") == 4
  doAssert robotIndexOfId("AZ-4") == -1
  doAssert robotIndexOfId("XX-1") == -1
  doAssert robotIndexOfId("") == -1
  for i in 0 ..< RobotCount:
    doAssert robotIndexOfId(robotId(i)) == i
  report "robot ids round-trip, case- and separator-tolerantly"

when isMainModule:
  echo "test_directives"
  idParsing()
  clipRunesIsExact()
  prosePrefixed()
  objectKeyedRobots()
  unknownEnumsRepair()
  badTargets()
  wrongRobotCounts()
  positionalAssignment()
  runeTruncation()
  noJsonAtAll()
  echo "test_directives: all good"
