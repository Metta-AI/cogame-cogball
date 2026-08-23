## Roster machinery: slot identities and limits, join/auth resolution, reward
## accounts, addPlayer/removePlayerAt, and `playerResultsJson`. Kept in ctf's
## shape; sole runtime consumer beyond the sim loop is server.nim.
##
## The results document must equal the manifest's `results_schema` KEY FOR KEY:
## that schema is `additionalProperties: false` and the certifier rejects any
## unknown field. ctf carries the scar (`shotsFired`/`shotsHit` were pulled
## back out of the payload for exactly this reason), so adding or removing a
## key here means editing coworld_manifest_template.json in the same commit —
## tests/test_manifest.nim fails until they agree.

import
  std/json,
  sim

proc canAddPlayer*(sim: SimServer): bool {.inline.} =
  sim.players.len < MaxPlayers

proc nextPlayerSlot*(sim: SimServer): int {.inline.} =
  ## Joins are strictly slot-sequential, so the seat a lobby is stuck waiting
  ## on is exactly this.
  sim.players.len

proc slotOfAddress(sim: SimServer, address: string): int =
  for i, player in sim.players:
    if player.address == address:
      return i
  -1

proc resolvePlayerSlot*(
  sim: SimServer,
  address: string,
  token: string,
  requestedSlot: int
): int =
  ## Where a pending connection wants to sit. An explicit slot wins; a token
  ## that matches a configured slot comes next; otherwise the next free seat.
  if requestedSlot >= 0 and requestedSlot < MaxPlayers:
    return requestedSlot
  if token.len > 0:
    for i, entry in sim.config.slots:
      if entry.token.len > 0 and entry.token == token:
        return i
  let existing = sim.slotOfAddress(address)
  if existing >= 0:
    return existing
  sim.nextPlayerSlot()

proc rewardAccountFor*(sim: var SimServer, address: string): int =
  for i in 0 ..< sim.rewardAccounts.len:
    if sim.rewardAccounts[i].address == address:
      return i
  sim.rewardAccounts.add RewardAccount(
    address: address, slotIndex: int32(sim.rewardAccounts.len))
  sim.rewardAccounts.len - 1

proc addPlayer*(
  sim: var SimServer,
  address: string,
  requestedSlot: int,
  token: string,
  trusted = false
): int =
  ## Seats one connection. Slot 0 is Azure, slot 1 is Crimson — the seat is a
  ## property of the SLOT, never of the connection order, so a replay re-seats
  ## exactly as the live match did.
  if sim.players.len >= MaxPlayers:
    raise newException(CogballError, "match is full")
  let slot = sim.players.len
  if not trusted and requestedSlot >= 0 and requestedSlot != slot:
    raise newException(CogballError,
      "player slot " & $requestedSlot & " is not the next open seat")
  var seat = if slot == 0: Azure else: Crimson
  if slot < sim.config.slots.len and sim.config.slots[slot].hasTeam:
    seat = sim.config.slots[slot].team
  var player = Player(
    address: address,
    joinOrder: int32(slot),
    seat: seat,
    policyLabel: policyName(address),
    policyKind: pkScripted,
    baseline: "formation"
  )
  sim.players.add(player)
  let account = sim.rewardAccountFor(address)
  sim.rewardAccounts[account].seat = seat
  sim.rewardAccounts[account].hasSeat = true
  inc sim.rewardAccounts[account].games[seat]
  sim.nextJoinOrder = int32(sim.players.len)
  sim.logGameEvent("player joined: " & address & " as " & seatAlias(seat))
  discard token
  slot

proc removePlayerAt*(sim: var SimServer, index: int) =
  ## Removes a roster entry. The SIX ROBOTS ARE NOT TOUCHED: they are fixed for
  ## the whole match, so unlike ctf (a per-player game) nothing renumbers when
  ## a seat leaves — see the second named edit in replays.nim.
  if index < 0 or index >= sim.players.len:
    return
  sim.logGameEvent("player left: " & sim.players[index].address)
  sim.players.delete(index)

proc recordGameAbandon*(sim: var SimServer, index: int) =
  if index < 0 or index >= sim.players.len:
    return
  let account = sim.rewardAccountFor(sim.players[index].address)
  sim.rewardAccounts[account].abandoned = true

proc seatOfSlot*(sim: SimServer, slot: int): Seat =
  if slot >= 0 and slot < sim.players.len:
    return sim.players[slot].seat
  if slot == 1: Crimson else: Azure

proc playerFor*(sim: SimServer, seat: Seat): int =
  for i, player in sim.players:
    if player.seat == seat:
      return i
  -1

proc roundDiv(a, b: int): int {.inline.} =
  ## Round-half-away-from-zero integer division; symmetric under negation, so
  ## the two seats' permille scores always sum to exactly 1000.
  if a >= 0: (2 * a + b) div (2 * b)
  else: -((2 * -a + b) div (2 * b))

proc scorePermille*(sim: SimServer, seat: Seat): int =
  ## `0.5 + 0.5 * clamp(gd / 3, -1, +1)`, in permille so the pair is exactly
  ## complementary. Higher is better; 3-0 or better = 1000, any draw = 500.
  if sim.endReason == reasonFault:
    return 500
  500 + clamp(roundDiv(sim.goalDiff(seat) * 500, 3), -500, 500)

proc seatWon*(sim: SimServer, seat: Seat): bool {.inline.} =
  sim.endReason != reasonFault and sim.goalDiff(seat) > 0

proc seatName*(sim: SimServer, seat: Seat): string =
  ## The REAL policy name (spectator side). Falls back to the configured slot
  ## name, then to the alias, so results are never empty.
  let index = sim.playerFor(seat)
  if index >= 0 and sim.players[index].address.len > 0:
    return sim.players[index].address
  let slot = ord(seat)
  if slot < sim.config.slots.len and sim.config.slots[slot].name.len > 0:
    return sim.config.slots[slot].name
  seatAlias(seat)

proc playerResultsJson*(sim: SimServer): string =
  ## The results artifact. Exactly the fifteen keys the manifest's
  ## `results_schema` declares, every array of length two, in seat order.
  var
    names = newJArray()
    scores = newJArray()
    win = newJArray()
    team = newJArray()
    goals = newJArray()
    shots = newJArray()
    onTarget = newJArray()
    saves = newJArray()
    possession = newJArray()
    llmTurns = newJArray()
    fallbackTurns = newJArray()
  for seat in Seat:
    names.add(%sim.seatName(seat))
    scores.add(%(float(sim.scorePermille(seat)) / 1000.0))
    win.add(%sim.seatWon(seat))
    team.add(%seatText(seat))
    goals.add(%sim.goals(seat))
    shots.add(%int(sim.stats[seat].shots))
    onTarget.add(%int(sim.stats[seat].shotsOnTarget))
    saves.add(%int(sim.stats[seat].saves))
    possession.add(%int(sim.stats[seat].possessionTicks))
    llmTurns.add(%int(sim.stats[seat].llmTurns))
    fallbackTurns.add(%int(sim.stats[seat].fallbackTurns))
  $(%*{
    "names": names,
    "scores": scores,
    "win": win,
    "team": team,
    "goals": goals,
    "shots": shots,
    "shotsOnTarget": onTarget,
    "saves": saves,
    "possessionTicks": possession,
    "llmTurns": llmTurns,
    "fallbackTurns": fallbackTurns,
    "reason": reasonText(sim.endReason),
    "endRule": endRuleText(sim.endRule),
    "finalTick": sim.tickCount,
    "seed": sim.config.seed
  })

proc resultRecordJson*(sim: SimServer): string =
  ## The `result` replay chat record: the full results document, written once
  ## at game over so `tools/replay_summary.py` can report the outcome from the
  ## bytes alone.
  $(%*{"k": "result", "results": parseJson(sim.playerResultsJson())})
