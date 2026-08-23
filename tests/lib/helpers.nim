## Shared helpers for the cogball test suite.
##
## Every test runs from the repo ROOT (assets resolve via `data/`), twice: once
## debug — where Nim's range and overflow checks are the cheapest catch for a
## fixed-point overflow — and once `-d:release`.

import std/[os, random, strutils]
import bitworld/spriteprotocol
import cogball/[baselines, control, decide, directives, roster, sim]

export sim, control, baselines, directives, decide, roster,
  spriteprotocol

proc testConfig*(seed = 679961, maxTicks = DefaultMaxTicks): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.maxTicks = maxTicks
  result.minPlayers = 2
  result.startWaitTicks = 1
  result.gameOverTicks = 2
  result.slots = @[
    PlayerSlotConfig(name: "azure-policy", token: "t0", team: Azure,
      hasTeam: true),
    PlayerSlotConfig(name: "crimson-policy", token: "t1", team: Crimson,
      hasTeam: true)
  ]

proc seatedSim*(config: GameConfig): SimServer =
  ## A sim with both seats already joined THROUGH `addPlayer`, logging off.
  ## Adding roster entries by hand would leave `nextJoinOrder` behind, and that
  ## field IS hashed — a replay of such a recording diverges at tick 1.
  result = initSimServer(config)
  result.gameEventLoggingEnabled = false
  discard result.addPlayer("azure-policy", 0, "t0")
  discard result.addPlayer("crimson-policy", 1, "t1")

proc playing*(config: GameConfig): SimServer =
  ## A sim already in the Playing phase, past the kickoff freeze.
  result = seatedSim(config)
  result.startGame()
  result.freezeUntil = 0

proc zeroInputs*(): seq[InputState] =
  newSeq[InputState](RobotCount)

proc stepWith*(sim: var SimServer, masks: array[RobotCount, uint8]) =
  var inputs = newSeq[InputState](RobotCount)
  for i in 0 ..< RobotCount:
    inputs[i] = decodeInputMask(masks[i])
  sim.step(inputs, inputs)

proc stepIdle*(sim: var SimServer, ticks = 1) =
  let idle = zeroInputs()
  for _ in 0 ..< ticks:
    sim.step(idle, idle)

type ScriptedMatch* = object
  goals*: array[Seat, int]
  ticks*: int
  reason*: EndReason
  rule*: EndRule
  masks*: seq[array[RobotCount, uint8]]

proc runScriptedMatch*(
  config: GameConfig,
  azure = "formation",
  crimson = "formation",
  collectMasks = false
): ScriptedMatch =
  ## A whole episode driven by the scripted baselines through the REAL control
  ## layer — the same path the server takes, minus the sockets.
  var sim = seatedSim(config)
  var directives: array[Seat, Directive]
  for seat in Seat:
    directives[seat] = emptyDirective(seat)
  var prev = newSeq[InputState](RobotCount)
  var guard = 0
  while sim.phase != GameOver and guard < config.maxTicks * 3 + 5000:
    inc guard
    if sim.phase == Playing:
      let elapsed = sim.tickCount - sim.gameStartTick
      if elapsed mod sim.turnTicks() == 0 or
          not (sim.hasDirective[Azure] and sim.hasDirective[Crimson]):
        let turn = elapsed div sim.turnTicks()
        directives[Azure] = sim.baselineDirective(Azure, azure, turn)
        directives[Crimson] = sim.baselineDirective(Crimson, crimson, turn)
        for seat in Seat:
          sim.activeDirective[seat] = directives[seat]
          sim.hasDirective[seat] = true
    let masks = sim.compileMasks(sim.activeDirective)
    if collectMasks:
      result.masks.add(masks)
    var inputs = newSeq[InputState](RobotCount)
    for i in 0 ..< RobotCount:
      inputs[i] = decodeInputMask(masks[i])
    sim.step(inputs, prev)
    prev = inputs
  for seat in Seat:
    result.goals[seat] = sim.goals(seat)
  result.ticks = sim.tickCount
  result.reason = sim.endReason
  result.rule = sim.endRule

proc sourceText*(path: string): string =
  ## Reads a source file with `##`/`#` comments and string literals stripped,
  ## so a guard can grep for IDENTIFIERS without tripping over prose.
  let raw = readFile(path)
  var
    stripped = newStringOfCap(raw.len)
    inString = false
    inChar = false
    escaped = false
    comment = false
    prev = ' '
  for ch in raw:
    if comment:
      if ch == '\n':
        comment = false
        stripped.add(ch)
      continue
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    if inChar:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '\'': inChar = false
      continue
    case ch
    of '#':
      comment = true
    of '"':
      inString = true
    of '\'':
      # A quote after an alphanumeric is a NUMERIC SUFFIX (`1'i64`), not a
      # char literal. Missing that swallows half the file and makes this guard
      # silently useless.
      if prev in {'0' .. '9', 'A' .. 'Z', 'a' .. 'z', '_'}:
        stripped.add(ch)
      else:
        inChar = true
    else:
      stripped.add(ch)
    prev = ch
  stripped

proc identifiers*(text: string): seq[string] =
  ## Every maximal [A-Za-z0-9_] run in `text`.
  var current = ""
  for ch in text:
    if ch in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}:
      current.add(ch)
    elif current.len > 0:
      result.add(current)
      current = ""
  if current.len > 0:
    result.add(current)

proc tempPath*(name: string): string =
  getTempDir() / ("cogball-test-" & $getCurrentProcessId() & "-" & name)

proc report*(name: string) =
  echo "  ok  ", name

proc pseudoWorld*(sim: var SimServer, rng: var Rand) =
  ## Scatters the seven bodies over the pitch deterministically — the state
  ## generator the bounded-orders and control tests sweep over.
  sim.ball.x = int32(PitchXMin + rng.rand(int(PitchXMax - PitchXMin)))
  sim.ball.y = int32(rng.rand(int(WorldH)))
  sim.ball.vx = int32(rng.rand(2 * int(BallMaxSpeed)) - int(BallMaxSpeed))
  sim.ball.vy = int32(rng.rand(2 * int(BallMaxSpeed)) - int(BallMaxSpeed))
  for i in 0 ..< RobotCount:
    sim.robots[i].x = int32(PitchXMin + RobotRadius +
      rng.rand(int(PitchXMax - PitchXMin - 2 * RobotRadius)))
    sim.robots[i].y = int32(RobotRadius +
      rng.rand(int(WorldH - 2 * RobotRadius)))
    sim.robots[i].vx = int32(rng.rand(2 * int(RobotMaxSpeed)) -
      int(RobotMaxSpeed))
    sim.robots[i].vy = int32(rng.rand(2 * int(RobotMaxSpeed)) -
      int(RobotMaxSpeed))
    sim.robots[i].headingQ = int32(rng.rand(HeadingQTurn - 1))
    sim.robots[i].spin = int32(rng.rand(2 * int(SpinMax)) - int(SpinMax))
    sim.robots[i].kickCooldown = int32(rng.rand(int(KickCooldownTicks)))

proc runeCount*(text: string): int =
  ## Codepoints, not bytes — the unit every recorded string is capped in.
  var count = 0
  var i = 0
  while i < text.len:
    let b = text[i].uint8
    let width =
      if b < 0x80: 1
      elif b < 0xE0: 2
      elif b < 0xF0: 3
      else: 4
    i += width
    inc count
  count

proc isValidUtf8*(text: string): bool =
  ## A byte-truncated multi-byte character is exactly the bug the rune
  ## discipline exists to prevent, so the tests check for it directly.
  var i = 0
  while i < text.len:
    let b = text[i].uint8
    var extra = 0
    if b < 0x80: extra = 0
    elif b >= 0xC2 and b <= 0xDF: extra = 1
    elif b >= 0xE0 and b <= 0xEF: extra = 2
    elif b >= 0xF0 and b <= 0xF4: extra = 3
    else: return false
    if i + extra >= text.len and extra > 0:
      return false
    for k in 1 .. extra:
      let c = text[i + k].uint8
      if c < 0x80 or c > 0xBF:
        return false
    i += extra + 1
  true

proc containsText*(haystack, needle: string): bool =
  needle.len > 0 and haystack.contains(needle)
