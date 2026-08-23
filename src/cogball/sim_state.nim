## Sim-state services shared by the roster machinery and the gameplay core:
## lobby status, game-event logging, the replay hash (gameHash / mixHash), and
## the tier-2 event sink (emitEvent). Stage 5 of ctf's sim split, kept.
##
## `gameHash` is the determinism contract with the wasm viewer: it mixes the
## tick, the phase, the verdict, the score and every body's position, velocity,
## heading, spin and cooldown — and NOTHING else. Directives, notes, FX, trails
## and paint never enter it, exactly as ctf keeps damagePops and skin out.

import
  std/strutils,
  sim_types

proc lobbyIsStarting*(sim: SimServer): bool =
  sim.players.len >= sim.config.minPlayers

proc lobbyStartTicksRemaining*(sim: SimServer): int =
  if not sim.lobbyIsStarting() or sim.config.startWaitTicks <= 0:
    return 0
  if sim.startWaitTimer > 0: sim.startWaitTimer else: sim.config.startWaitTicks

proc lobbyStartSecondsRemaining*(sim: SimServer): int =
  let ticks = sim.lobbyStartTicksRemaining()
  if ticks <= 0:
    return 0
  max(1, (ticks + TargetFps - 1) div TargetFps)

proc lobbyJoinTimedOut*(sim: SimServer): bool =
  ## True when a finite match has waited out `lobbyJoinTimeoutTicks` lobby
  ## ticks still short of `minPlayers`. The clock runs on LOBBY ticks, so the
  ## turf bake before the loop starts never eats the budget.
  sim.phase == Lobby and sim.config.lobbyJoinTimeoutTicks > 0 and
    sim.players.len < sim.config.minPlayers and
    sim.lobbyWaitTimer >= sim.config.lobbyJoinTimeoutTicks

proc logGameEvent*(sim: SimServer, text: string) =
  if sim.gameEventLoggingEnabled:
    echo text

proc logLobbyWaiting*(sim: var SimServer) =
  let
    needed = max(0, sim.config.minPlayers - sim.players.len)
    players = sim.players.len
  if players == sim.lastLobbyPlayersLogged and
      needed == sim.lastLobbyNeededLogged:
    return
  sim.lastLobbyPlayersLogged = players
  sim.lastLobbyNeededLogged = needed
  sim.lastLobbySecondsLogged = -1
  sim.logGameEvent("waiting for players: " & $players & "/" &
    $sim.config.minPlayers & ", need " & $needed & " more")

proc logLobbyCountdown*(sim: var SimServer) =
  let seconds = sim.lobbyStartSecondsRemaining()
  if seconds <= 0 or seconds == sim.lastLobbySecondsLogged:
    return
  sim.lastLobbySecondsLogged = seconds
  sim.logGameEvent("game starting in " & $seconds)

proc mixHash(hash: var uint64, value: uint64) {.inline.} =
  ## FNV-1a, ctf's mixer, unchanged.
  hash = hash xor value
  hash *= 1099511628211'u64

proc mixHashI32(hash: var uint64, value: int32) {.inline.} =
  hash.mixHash(cast[uint64](int64(value)))

proc mixHashInt(hash: var uint64, value: int) {.inline.} =
  hash.mixHash(cast[uint64](int64(value)))

proc mixHashBool(hash: var uint64, value: bool) {.inline.} =
  hash.mixHashInt(ord(value))

proc gameHash*(sim: SimServer): uint64 =
  ## A deterministic hash of gameplay state. Written once per tick into the
  ## replay and re-derived by the wasm viewer; a single divergent bit surfaces
  ## at the tick it happens.
  result = 14695981039346656037'u64
  result.mixHashInt(sim.tickCount)
  result.mixHashInt(ord(sim.phase))
  result.mixHashInt(ord(sim.winner))
  result.mixHashBool(sim.isDraw)
  result.mixHashBool(sim.ended)
  result.mixHashInt(ord(sim.endReason))
  result.mixHashInt(ord(sim.endRule))
  result.mixHashInt(sim.gameOverTimer)
  result.mixHashInt(sim.gameStartTick)
  result.mixHashInt(sim.startWaitTimer)
  result.mixHashI32(sim.freezeUntil)
  result.mixHashI32(sim.restartSeat)
  result.mixHashI32(sim.stalemateTicks)
  result.mixHashI32(sim.anchorX)
  result.mixHashI32(sim.anchorY)
  result.mixHashBool(sim.needsReregister)
  result.mixHashI32(sim.nextJoinOrder)
  result.mixHashI32(sim.ball.x)
  result.mixHashI32(sim.ball.y)
  result.mixHashI32(sim.ball.vx)
  result.mixHashI32(sim.ball.vy)
  for robot in sim.robots:
    result.mixHashI32(robot.x)
    result.mixHashI32(robot.y)
    result.mixHashI32(robot.vx)
    result.mixHashI32(robot.vy)
    result.mixHashI32(robot.headingQ)
    result.mixHashI32(robot.spin)
    result.mixHashI32(robot.kickCooldown)
    result.mixHashI32(robot.seat)
  for seat in Seat:
    result.mixHashI32(sim.stats[seat].goals)
    result.mixHashI32(sim.stats[seat].shots)
    result.mixHashI32(sim.stats[seat].shotsOnTarget)
    result.mixHashI32(sim.stats[seat].saves)
    result.mixHashI32(sim.stats[seat].possessionTicks)
    result.mixHashI32(sim.stats[seat].kicks)
    result.mixHashI32(sim.stats[seat].passesCompleted)
    result.mixHashI32(sim.stats[seat].interceptions)
  result.mixHashI32(sim.lastTouch.robot)
  result.mixHashI32(sim.lastTouch.seat)
  result.mixHashI32(sim.lastTouch.tick)
  result.mixHashI32(sim.prevTouch.robot)
  result.mixHashI32(sim.prevTouch.seat)
  result.mixHashI32(sim.prevTouch.tick)
  result.mixHashI32(sim.pendingShot.seat)
  result.mixHashI32(sim.pendingShot.robot)
  result.mixHashI32(sim.pendingShot.tick)
  result.mixHashBool(sim.pendingShot.onTarget)
  result.mixHashI32(sim.pendingPass.seat)
  result.mixHashI32(sim.pendingPass.robot)
  result.mixHashI32(sim.pendingPass.tick)
  result.mixHashI32(sim.pendingPass.target)
  result.mixHashInt(sim.players.len)
  for player in sim.players:
    result.mixHashI32(player.joinOrder)
    result.mixHashInt(ord(player.seat))

proc emitEvent*(
  sim: var SimServer,
  kind: SimEventKind,
  source = -1,
  target = -1,
  seat = -1,
  amount = 0,
  x: int32 = 0,
  y: int32 = 0,
  speed: int32 = 0,
  content = ""
) {.inline.} =
  ## Appends one tier-2 analysis event. A no-op unless `collectEvents` is on,
  ## so a live server that nobody is analysing pays nothing.
  if not sim.collectEvents:
    return
  sim.events.add SimEvent(
    tick: sim.tickCount,
    kind: kind,
    source: source,
    target: target,
    seat: seat,
    amount: amount,
    x: x,
    y: y,
    speed: speed,
    content: content
  )

proc emitPhaseChange*(sim: var SimServer, newPhase: GamePhase) {.inline.} =
  ## Call BEFORE assigning sim.phase, with the phase being switched to.
  if not sim.collectEvents:
    return
  sim.emitEvent(PhaseChange, amount = ord(newPhase),
    content = ($newPhase).toLowerAscii)
