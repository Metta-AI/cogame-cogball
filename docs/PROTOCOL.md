# Cogball — wire protocol

Two protocols matter here: the **player** protocol (what a policy container
speaks to the game) and the **global** protocol (what a spectator or the static
replay viewer speaks). Both are Sprite v1 binary websocket streams, exactly as
in the paintbot lineage.

## Runtime contract

The game container reads and writes the standard `COGAME_*` URIs:

| variable | meaning |
|---|---|
| `COGAME_CONFIG_URI` | the episode config JSON (read at startup) |
| `COGAME_RESULTS_URI` | the results document (written once, at game over) |
| `COGAME_SAVE_REPLAY_URI` | the `COWLDBAL` replay bytes |
| `COGAME_LOAD_REPLAY_URI` | a replay to serve instead of playing a match |
| `COGAME_PLAYER_FAILURE_URI` | `{"failed_policy_index": N, "message": "…"}` |
| `COGAME_EVENTS_URI` | the tier-2 JSON-lines analysis stream (`file://` only) |
| `COGAME_HOST` / `COGAME_PORT` | the bind address (default `0.0.0.0:8080`) |
| `ANTHROPIC_API_KEY` / `ANTHROPIC_API_KEY_URI` | the coaching credential |

## Routes

| route | method | purpose |
|---|---|---|
| `/healthz` | GET | liveness; returns `healthy` |
| `/player?slot=N&token=T` | GET (ws) | one seat's stream |
| `/global` | GET (ws) | the spectator board |
| `/replay` | GET (ws) | the replay board (replay mode) |
| `/client/global`, `/client/player` | GET | the bitworld generic clients |
| `/client/replay` | GET | the designed broadcast client |
| `/client/league` | GET | the League Replayer shell (embeds the above) |
| `/client/font.ttf` | GET | the chrome font |
| `/replay-data` | GET | the current replay bytes |

A bad slot or a token that does not match the configured slot is refused with
**403 before the websocket upgrade**. A viewer socket that carries player
credentials is refused the same way.

## The player protocol

### Registration — the only thing a seat ever sends that matters

On connect, a seat sends **one Sprite v1 chat message** (`0x81`, u16 length,
then the raw payload) carrying:

```json
{"type":"register",
 "prompt":"<strategy text or empty>",
 "scripted":"formation"|"swarm"|null,
 "policy":"<free label>"}
```

* A non-empty `prompt` makes the seat an **LLM seat**: the game server sends
  that text to Claude once per coaching turn.
* Otherwise `scripted` selects a built-in baseline; an unknown or absent value
  is `formation`.
* `policy` is a free label, capped at **48 runes**, recorded in the replay.
* `prompt` is capped at **4000 runes** at the transport (over-long is
  truncated, never rejected) and is **never** written to the replay or the
  results.

The payload is read WITHOUT an ASCII filter, so a non-ASCII policy label
survives to the replay intact. Registration is re-sent once after the first
received frame, in case the first send raced the slot registration.

The server **intercepts** the registration: it is consumed, not written to the
replay chat stream. A redacted `register` record is written instead. **Any
other chat text from a player is dropped.**

### Frames

Each seat's websocket receives one binary Sprite v1 message per tick.

**Visible:** the whole pitch and every body — soccer is a perfect-information
sport, so there is no fog of war; the score; the clock; a self marker on its own
three robots; and an invisible `own seat <alias>` marker naming the seat.

**Hidden:** the opponent's directives, roles, intents, `note`/`say` and prompt;
the episode seed; **real player names** (board labels carry only `Azure`/
`Crimson` and `AZ-1..3`/`CR-1..3`); and future ticks.

A seat sends **no inputs** — the server computes every actuator mask — so the
Sprite v1 Ready packet (`0x85`) is legitimate after each received frame and is
what lets `fastMode` pace the match by readiness. (ctf's warning about `0x85`
corrupting input timing is about *player* clients whose own inputs are
dead-reckoned; that hazard does not exist here.)

## The replay bytes

The replay is the starter's **binary `COWLDBAL`** format — the same format the
static wasm viewer parses. Everything the viewer needs is in the bytes; no
server is contacted except S3 for the file.

| content | carries |
|---|---|
| header | magic `COWLDBAL`, format version, game name `cogball`, game version `1` |
| config JSON | seed, `num_agents`, `maxTicks`, `turnTicks`, every physics constant, `players[].name`, `slots[].team`, `fastMode` |
| joins | per seat: name, slot, token |
| inputs | per **robot** (0..5), on change: the `uint8` actuator mask — the action log |
| chats | the `register` / `directive` / `fallback` / `budget_guard` / `result` records |
| hashes | one `gameHash` per tick — the integrity chain the viewer checks |

Masks are indexed by **robot**, not by roster slot, and a player leaving does
**not** shift the mask arrays: cogball's six robots are fixed for the whole
match.

### Record vocabulary

| `k` | fields |
|---|---|
| `register` | `seat`, `alias`, `policy` (≤48 runes), `kind` (`llm`\|`scripted`), `baseline` |
| `directive` | `turn`, `seat`, `alias`, `source` (`llm`\|`scripted`\|`fallback`), `latency_ms`, `note`, `robots`:[{`id`,`role`,`intent`,`target`,`pass_to`,`kick`,`say`}] |
| `fallback` | `turn`, `seat`, `attempt` (1\|2), `cause`, `detail` (≤200 runes) |
| `budget_guard` | `turn`, `remaining_s` |
| `result` | the full results document, written once at game over |

Every record is capped at **900 runes**, on a rune boundary.

### Reading a replay without Nim

`tools/replay_summary.py` (Python 3 standard library only — no Nim, no Docker)
prints one strict-UTF-8 JSON object describing a `.bitreplay`:

```bash
python3 tools/replay_summary.py /tmp/ep.replay | jq .
```

```json
{"protocol":"cogball/v1","gameVersion":"1","seed":679961,
 "names":[…],"aliases":["Azure","Crimson"],"policyKinds":[…],
 "tickCount":4800,"directives":[…],"fallbacks":0,"results":{…}}
```

## Derived broadcast events

`stepEvents` derives these from state deltas during playback, so they cost no
replay bytes and are identical live and in replay: `phase`, `kick`, `touch`,
`shot`, `save`, `pass`, `interception`, `goal`, `kickoff`, `drop`, `turn_end`,
`gameover`. `goal` and `drop` are **beats** — scrubber markers, and the trigger
for the slow-mo goal replay. `touch` is throttled to at most one per robot per
6 ticks.

## Results document

Written to `COGAME_RESULTS_URI`. It equals the manifest's `results_schema`
key for key; that schema is `additionalProperties: false` and the certifier
rejects any unknown field.

```json
{"names": ["daveey", "daveey-1"],
 "scores": [0.667, 0.333],
 "win": [true, false],
 "team": ["azure", "crimson"],
 "goals": [2, 1],
 "shots": [9, 6],
 "shotsOnTarget": [4, 2],
 "saves": [1, 3],
 "possessionTicks": [2640, 2160],
 "llmTurns": [40, 0],
 "fallbackTurns": [0, 0],
 "reason": "complete",
 "endRule": "full_time",
 "finalTick": 4800,
 "seed": 679961}
```

`names` are the **real policy names** (spectator side). `team` carries the
in-game aliases.
