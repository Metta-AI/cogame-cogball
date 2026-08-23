## Directives: the coaching object a seat plays for one 120-tick turn, its
## tolerant parser/repairer, and the view-coordinate transform every policy
## sees the world through.
##
## Two hard rules live here and are pinned by tests/test_directives.nim:
##
## 1. **Every recorded string is truncated on RUNE boundaries, never bytes.**
##    A byte-truncated multi-byte character is exactly the bug that makes
##    replay bytes render in a browser but fail a strict parser.
## 2. **Parsing is tolerant and never fails hard.** Markdown fences, prose
##    prefixes, an id-keyed `robots` object, numeric strings, unknown enums,
##    out-of-pitch targets, four robots, zero robots — all repair. Only when no
##    object with at least one usable robot entry can be recovered do the retry
##    and then the scripted fallback fire.

import
  std/[json, math, strutils, unicode],
  sim

# --------------------------------------------------------------------------
# View coordinates: metres from the centre spot. The ONLY coordinates a policy
# ever sees or sends.
# --------------------------------------------------------------------------

const
  ViewHalfW* = 20.0
  ViewHalfH* = 12.5
  GoalHalfWidth* = 3.5

proc viewX*(x: int32): float {.inline.} =
  float(int(x) - int(CentreX)) / 1_000_000.0

proc viewY*(y: int32): float {.inline.} =
  float(int(y) - int(CentreY)) / 1_000_000.0

proc worldXOfView*(v: float): int32 {.inline.} =
  int32(int(CentreX) + int(round(clamp(v, -ViewHalfW, ViewHalfW) * 1_000_000.0)))

proc worldYOfView*(v: float): int32 {.inline.} =
  int32(int(CentreY) + int(round(clamp(v, -ViewHalfH, ViewHalfH) * 1_000_000.0)))

proc round2*(value: float): float {.inline.} =
  ## Two decimals, the precision every number in the seat view carries.
  round(value * 100.0) / 100.0

# --------------------------------------------------------------------------
# Rune-boundary truncation
# --------------------------------------------------------------------------

proc clipRunes*(text: string, maxRunes: int): string =
  ## Truncates on a RUNE boundary (babel's `cleanNotes`, ported). Slicing a
  ## `string` by byte index on any path to the replay is forbidden.
  result = text.strip()
  var clean = newStringOfCap(result.len)
  for rune in result.runes:
    # Control characters would corrupt a replay chat record and a JSON line.
    if int32(rune) >= 32 or int32(rune) == 9:
      clean.add($rune)
  result = clean
  if maxRunes <= 0:
    return ""
  if result.runeLen <= maxRunes:
    return
  result = result.runeSubStr(0, maxRunes - 1) & "\u2026"

# --------------------------------------------------------------------------
# Robot ids
# --------------------------------------------------------------------------

proc robotIndexOfId*(id: string): int =
  ## `AZ-1`..`AZ-3` / `CR-1`..`CR-3`, case-insensitive, separator-tolerant.
  ## -1 when the token names no robot.
  let text = clipRunes(id, MaxRobotIdRunes).toUpperAscii()
  var digits = ""
  var prefix = ""
  for ch in text:
    if ch in {'A' .. 'Z'}:
      if prefix.len < 2: prefix.add(ch)
    elif ch in {'0' .. '9'}:
      digits.add(ch)
  if digits.len == 0:
    return -1
  var slot: int
  try:
    slot = parseInt(digits)
  except ValueError:
    return -1
  if slot < 1 or slot > RobotsPerSeat:
    return -1
  case prefix
  of "AZ": firstRobotOf(Azure) + slot - 1
  of "CR": firstRobotOf(Crimson) + slot - 1
  else: -1

# --------------------------------------------------------------------------
# Enum repair
# --------------------------------------------------------------------------

proc roleOfText*(text: string): Role =
  case text.strip().toLowerAscii()
  of "keeper": roleKeeper
  of "back": roleBack
  of "striker": roleStriker
  else: roleWing        ## the documented repair for an unknown role.

proc intentOfText*(text: string): Intent =
  case text.strip().toLowerAscii()
  of "intercept": inIntercept
  of "hold": inHold
  of "shoot": inShoot
  of "pass": inPass
  of "clear": inClear
  of "press": inPress
  else: inChase         ## the documented repair for an unknown intent.

proc kickOfText*(text: string): KickMode =
  if text.strip().toLowerAscii() == "never": kickNever else: kickAuto

# --------------------------------------------------------------------------
# Directive construction and serialization
# --------------------------------------------------------------------------

proc emptyDirective*(seat: Seat): Directive =
  result.source = dsScripted
  for slot in 0 ..< RobotsPerSeat:
    result.robots[slot] = RobotOrder(
      role: roleWing, intent: inChase,
      targetX: CentreX, targetY: CentreY,
      passTo: -1, kick: kickAuto, say: "")
  discard seat

proc directiveJson*(sim: SimServer, seat: Seat, directive: Directive): JsonNode =
  ## The `directive` replay chat record. Capped at MaxDirectiveRecordRunes by
  ## the caller (`recordRunes` below).
  var robots = newJArray()
  for slot in 0 ..< RobotsPerSeat:
    let order = directive.robots[slot]
    robots.add(%*{
      "id": robotId(firstRobotOf(seat) + slot),
      "role": roleText(order.role),
      "intent": intentText(order.intent),
      "target": [round2(viewX(order.targetX)), round2(viewY(order.targetY))],
      "pass_to": (if order.passTo >= 0: %robotId(int(order.passTo)) else: newJNull()),
      "kick": kickText(order.kick),
      "say": order.say
    })
  %*{
    "k": "directive",
    "turn": directive.turn,
    "seat": ord(seat),
    "alias": seatAlias(seat),
    "source": sourceText(directive.source),
    "latency_ms": directive.latencyMs,
    "note": directive.note,
    "robots": robots
  }

proc clipJsonStrings(node: JsonNode, budget: int): JsonNode =
  ## A copy of `node` with every STRING VALUE clipped to `budget` runes. Keys
  ## are untouched, so the shape a reader matches on survives.
  case node.kind
  of JString:
    result = %clipRunes(node.getStr(), budget)
  of JArray:
    result = newJArray()
    for item in node:
      result.add(clipJsonStrings(item, budget))
  of JObject:
    result = newJObject()
    for key, value in node:
      result[key] = clipJsonStrings(value, budget)
  else:
    result = node

proc capRecord*(text: string): string =
  ## Every replay chat record is capped at MaxDirectiveRecordRunes runes, on a
  ## rune boundary. ctf's 10-character shout cap is deliberately raised here.
  ##
  ## The cap is on the SERIALIZED record, and JSON escaping is what makes that
  ## non-obvious: a `"` or a `\` inside a note or a say costs two runes on the
  ## wire, so a directive whose note and three says are all legal at their own
  ## caps (160 + 3x48 runes) serializes to 1053 runes when every one of those
  ## characters escapes. Blindly clipping the serialized text at 900 would then
  ## cut the object mid-key: still valid UTF-8 on a rune boundary, but no
  ## longer JSON. `broadcast.applyRecord` would silently drop the feed line and
  ## `tools/replay_summary.py` would skip the record, so phase 60 would
  ## under-count exactly the LLM directives it is there to verify.
  ##
  ## So an over-long record is shrunk STRUCTURALLY: parse it, clip its string
  ## values to a halving budget until the serialization fits, and only fall
  ## back to the blind rune clip when the text is not a JSON object at all.
  ## The result is always parseable, and a record already inside the cap is
  ## returned byte for byte.
  if text.runeLen <= MaxDirectiveRecordRunes:
    return clipRunes(text, MaxDirectiveRecordRunes)
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return clipRunes(text, MaxDirectiveRecordRunes)
  if node.kind != JObject:
    return clipRunes(text, MaxDirectiveRecordRunes)
  var budget = MaxNoteRunes
  while budget > 0:
    budget = budget div 2
    let shrunk = $clipJsonStrings(node, budget)
    if shrunk.runeLen <= MaxDirectiveRecordRunes:
      return shrunk
  clipRunes(text, MaxDirectiveRecordRunes)

# --------------------------------------------------------------------------
# The tolerant parser
# --------------------------------------------------------------------------

proc numberOf(node: JsonNode, ok: var bool): float =
  ## Accepts a JSON number OR a numeric string; anything else, or a
  ## non-finite value, reports `ok = false`.
  ok = false
  if node.isNil:
    return 0.0
  case node.kind
  of JInt:
    ok = true
    return float(node.getInt())
  of JFloat:
    let value = node.getFloat()
    if value != value or value == Inf or value == NegInf:
      return 0.0
    ok = true
    return value
  of JString:
    try:
      let value = parseFloat(node.getStr().strip())
      if value != value or value == Inf or value == NegInf:
        return 0.0
      ok = true
      return value
    except ValueError:
      return 0.0
  else:
    return 0.0

proc entriesOf(node: JsonNode): seq[tuple[id: string, body: JsonNode]] =
  ## `robots` may arrive as an array of objects or as an object keyed by robot
  ## id. Both shapes reduce to (id, body) pairs; the id inside the body wins.
  if node.isNil:
    return
  case node.kind
  of JArray:
    for entry in node:
      if entry.kind == JObject:
        result.add((entry{"id"}.getStr(), entry))
  of JObject:
    for key, entry in node:
      if entry.kind == JObject:
        let inner = entry{"id"}.getStr()
        let useId = if inner.len > 0: inner else: key
        result.add((useId, entry))
  else:
    discard

proc parseDirective*(
  sim: SimServer,
  seat: Seat,
  payload: JsonNode,
  previous: Directive,
  hasPrevious: bool,
  fallback: Directive,
  turn: int
): tuple[directive: Directive, usable: bool] =
  ## Repairs one reply into a legal directive. `usable` is false when no robot
  ## entry could be recovered at all — the only case that triggers the retry.
  var directive = fallback
  directive.turn = int32(turn)
  directive.source = dsLlm
  directive.note = clipRunes(payload{"note"}.getStr(), MaxNoteRunes)

  let base = firstRobotOf(seat)
  var filled: array[RobotsPerSeat, bool]
  var entries = entriesOf(payload{"robots"})
  var positional = 0
  for entry in entries:
    var index = robotIndexOfId(entry.id)
    if index < 0 or seatOfRobot(index) != seat:
      # An unmatched (or other-team) id is assigned to this seat's robots by
      # position, in reply order.
      while positional < RobotsPerSeat and filled[positional]:
        inc positional
      if positional >= RobotsPerSeat:
        continue                      ## extra entries are dropped.
      index = base + positional
    let slot = index - base
    if slot < 0 or slot >= RobotsPerSeat or filled[slot]:
      continue
    filled[slot] = true
    var order = RobotOrder()
    order.role = roleOfText(entry.body{"role"}.getStr())
    order.intent = intentOfText(entry.body{"intent"}.getStr())
    order.kick = kickOfText(entry.body{"kick"}.getStr("auto"))
    order.say = clipRunes(entry.body{"say"}.getStr(), MaxSayRunes)
    # target: two finite numbers, clamped into the pitch; anything else falls
    # back to the robot's CURRENT position.
    var okX = false
    var okY = false
    var vx = 0.0
    var vy = 0.0
    let target = entry.body{"target"}
    if not target.isNil and target.kind == JArray and target.len >= 2:
      vx = numberOf(target[0], okX)
      vy = numberOf(target[1], okY)
    elif not target.isNil and target.kind == JObject:
      vx = numberOf(target{"x"}, okX)
      vy = numberOf(target{"y"}, okY)
    if okX and okY:
      order.targetX = worldXOfView(vx)
      order.targetY = worldYOfView(vy)
    else:
      order.targetX = sim.robots[index].x
      order.targetY = sim.robots[index].y
    # pass_to: a TEAMMATE id that is not this robot; anything else is null.
    order.passTo = -1
    let passNode = entry.body{"pass_to"}
    if not passNode.isNil and passNode.kind == JString:
      let mate = robotIndexOfId(passNode.getStr())
      if mate >= 0 and mate != index and seatOfRobot(mate) == seat:
        order.passTo = int32(mate)
    directive.robots[slot] = order

  var usable = false
  for slot in 0 ..< RobotsPerSeat:
    if filled[slot]:
      usable = true
    else:
      # A missing robot keeps last turn's order for that robot, else the
      # scripted fallback's.
      directive.robots[slot] =
        if hasPrevious: previous.robots[slot] else: fallback.robots[slot]
  (directive, usable)
