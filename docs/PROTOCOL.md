# Cogball — wire protocol

Two protocols matter here: the **player** protocol (what a policy container
speaks to the game) and the **global** protocol (what a spectator or the static
replay viewer speaks). Player frames use Sprite v1 binary messages, while
coaching decisions use JSON WebSocket text messages. Spectator frames use
Sprite v1.

## Runtime contract

The game container reads and writes the standard `COGAME_*` URIs:

| variable | meaning |
|---|---|
| `COGAME_CONFIG_URI` | the episode config JSON (read at startup) |
| `COGAME_RESULTS_URI` | the results document (written once, at game over) |
| `COGAME_SAVE_REPLAY_URI` | the `COWLDBAL` replay bytes |
| `COGAME_LOAD_REPLAY_URI` | a replay to serve instead of playing a match |
| `COGAME_PLAYER_FAILURE_URI` | `{"failed_policy_index": N, "message": "…"}` |
| `COGAME_SAVE_TRAJECTORY_URI` | private decision attempts and complete outcome (scoped file/PUT URI) |
| `COWORLD_EPISODE_ID`, `COWORLD_GAME_VERSION`, `COWORLD_SOURCE_REVISION` | required immutable identity when private capture is enabled |
| `COGAME_EVENTS_URI` | the tier-2 JSON-lines analysis stream (`file://` only) |
| `COGAME_HOST` / `COGAME_PORT` | the bind address (default `0.0.0.0:8080`) |
| `COWORLD_LLM_ENDPOINT`, `COWORLD_LLM_MODEL` | selected player native sidecar and requested model |

## Routes

| route | method | purpose |
|---|---|---|
| `/healthz` | GET | liveness; returns `healthy` |
| `/player?slot=N&token=T` | GET (ws) | one seat's stream |
| `/global` | GET (ws) | the spectator board |
| `/replay` | GET (ws) | the replay board (replay mode) |
| `/client/global`, `/client/player` | GET | the bitworld generic clients |
| `/client/replay` | GET | the designed broadcast client, **live pod only** |
| `/client/league` | GET | the League Replayer shell (embeds the above) |
| `/client/font.ttf` | GET | the chrome font |
| `/replay-data` | GET | the current replay bytes |

**The hosted replay viewer is never one of these routes.** It is the STATIC
wasm bundle: `coworld_manifest_template.json` declares
`"replay_viewer": {"bundle": "static-replay-viewer"}`,
`.github/workflows/coworld-release.yml` hard-fails certification if the
certifier reports anything else, and the bundle re-simulates in the browser and
fetches nothing but the S3 replay object. The `/client/*` pages above exist for
a **locally running game pod** — `docker run` + a browser — and nothing the
bundle ships names them: `tests/test_viewer.nim` asserts every source the
bundle is built from is free of the pod board's route.

A bad slot or a token that does not match the configured slot is refused with
**403 before the websocket upgrade**. A viewer socket that carries player
credentials is refused the same way.

## The player protocol

### Registration

On connect, a seat sends **one Sprite v1 chat message** (`0x81`, u16 length,
then the raw payload) carrying:

```json
{"type":"register",
 "kind":"prompt"|"external"|"scripted",
 "prompt":"<private operator guidance>",
 "scripted":"formation"|"swarm"|null,
 "policy":"<free label>"}
```

* `prompt` and `external` policies receive decision requests over the same player
  socket. The player runs inference and returns a directive. The game receives
  no model credential. Private `training_attempt` metadata carries the exact
  inference prompt, request, response, and actual native provenance.
* `scripted` selects a built-in baseline; an unknown or absent value is
  `formation`.
* `policy` is a free label, capped at **48 runes**, recorded in the replay.

The payload is read WITHOUT an ASCII filter, so a non-ASCII policy label
survives to the replay intact. The server retains registration when a player
connects before its configured seat is admitted.

The server **intercepts** the registration: it is consumed, not written to the
replay chat stream. A redacted `register` record is written instead. Other
Sprite chat text is dropped; decisions use WebSocket text messages.

### Coaching decisions

At a turn boundary the game issues an opaque, nonempty string identity:

```json
{"type":"decision","decision_id":"<issued identity>","seat":0,
 "observation":{"turn":0},
 "messages":[{"role":"system","content":"<rules>"},
             {"role":"user","content":"<private guidance and observation>"}],
 "transport":{"budget_ms":6000,"cleanup_budget_ms":5000,"max_output_tokens":900}}
```

Both seats receive the same frozen simulation state before either response is awaited.
The native worker honors the engine-issued positive output-token cap.
The original 9-second turn cap includes the 6-second first attempt and 2.5-second repair.
Repair receives the remaining time; interruption prevents new request issuance.
Before a subsequent request, the player joins the previous worker and sends
uncredited `stopped` evidence. It starts the new worker only after the matching
`evidence_received`, within the new request's original remaining budget.
The main reader continues to process terminal stop frames during that handoff.
Registration freezes when the real lobby transitions to play.

Before starting HTTP, the player sends `attempt_started` with the issued
`decision_id` and genuinely unobserved `training_attempt` response fields.
The action uses that identity and its completed native evidence:

```json
{"type":"action","decision_id":"<issued identity>",
 "action":{"note":"...","robots":[...]},"training_attempt":{}}
```

The game independently binds the received native body to the normalized completion
and production-parsed directive. A failed call returns `cause` and private evidence.
Missing endpoint means unsupervised fallback; credentials never activate inference.

At finalization, every registered player, including disconnected seats, must finish
its owned readers. The game sends `stop` with the latest `decision_id` (or null),
a random `stop_id`, and remaining `cleanup_budget_ms`. The player cancels and joins
its HTTP worker, then sends `stopped` with those identities, `worker_status` of
`joined` or `no_active_call`, and an `attempts` array of genuine final evidence.
The game retains late facts before nonce/window checks and returns
`evidence_received` with the echoed identities. The player waits for that receipt
before closing. Self-initiated stop may use a null nonce, without acknowledgement credit.

Unresolved cleanup yields private `truncated` status and no normal public result or replay.
All private and public artifact writes share one absolute cleanup deadline.

`training_attempt` is an optional private Bitworld evidence object; explicit null
means no supplied evidence. The engine owns inference mode, acceptance, parsed
action, and execution. Player teacher/human assertions become unknown. Model
responses must independently parse to the same canonical submitted action.
Metadata is never included in public replay records.

### Frames

Each seat's websocket receives one binary Sprite v1 message per tick.

**Visible:** the whole pitch and every body — soccer is a perfect-information
sport, so there is no fog of war; the score; the clock; a self marker on its own
three robots; and an invisible `own seat <alias>` marker naming the seat.

**Hidden:** the opponent's directives, roles, intents, `note`/`say` and prompt;
the episode seed; **real player names** (board labels carry only `Azure`/
`Crimson` and `AZ-1..3`/`CR-1..3`); and future ticks.

A seat sends **no motor inputs** — the server computes every actuator mask — so the
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
