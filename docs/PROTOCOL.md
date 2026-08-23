# cogball wire protocol

Everything a seat can see, and everything it may send. The authority for the
runtime contract is `server/cogball/server.py`; this page is the human-readable
version of it.

## Runtime contract (Coworld `COGAME_*`)

| variable | meaning |
| --- | --- |
| `COGAME_CONFIG_URI` | the episode config JSON (required in episode mode) |
| `COGAME_RESULTS_URI` | where `results.json` is written |
| `COGAME_SAVE_REPLAY_URI` | where the replay JSON is written |
| `COGAME_PLAYER_FAILURE_URI` | where a no-show seat is declared |
| `COGAME_LOAD_REPLAY_URI` | set ⇒ replay mode: serve a recorded replay, run no episode |
| `COGAME_HOST` / `COGAME_PORT` | bind address (default `0.0.0.0:8080`) |

Routes: `GET /healthz`, `GET /player?slot=N&token=T` (websocket),
`GET /global` (broadcast websocket), `GET /client/global`,
`GET /client/player`, and in replay mode `GET /replay-data` +
`GET /client/replay`. A bad slot or token is `403`; a second connection to an
already-connected slot is `409`.

## The episode config

```json
{"seed": 2864434397, "max_ticks": 7200, "turn_ticks": 150,
 "turn_budget_seconds": 12, "tick_deadline_ms": 1000,
 "player_connect_timeout_seconds": 90, "wall_clock_budget_seconds": 690,
 "num_agents": 2,
 "players": [{"name": "Azure"}, {"name": "Magenta"}],
 "tokens": ["token-0", "token-1"]}
```

`seed` may be omitted; the server derives one and records it in the results and
the replay. `num_agents`, if present, must equal the seat count.

## What a player sends: one frame, ever

Decisions are made by the **game server** — the hosted Bedrock credential and
the `anthropic_api_key` Coworld secret are injected into the game pod — so a
player container is thin. On connect it sends exactly one frame and then only
receives:

```json
{"type": "register",
 "prompt": "<strategy text, or empty>",
 "scripted": "formation" | "swarm" | null,
 "policy": "<free label, <= 48 runes>"}
```

A non-empty `prompt` makes the seat an **LLM seat**: that text is the policy,
and the server asks Claude for a directive every turn on the seat's behalf. A
seat that registers with neither field — or never registers at all, or never
connects — plays the `formation` baseline. An over-long `prompt` is truncated
to 4 000 runes, not rejected; it is never written to the replay or the results.

## What the server sends

Once per decision turn (every `turn_ticks` = 150 ticks = 5.0 s):

```json
{"type": "turn", "turn": 7, "tick": 1050, "view": { … },
 "directive_source": "llm"}
```

and at the end, followed by close:

```json
{"done": true, "result": { …the results document… }}
```

`GET /global` is broadcast-only: a status snapshot on connect, a throttled
`{"tick": t}` progress feed, then the same done message.

## The per-seat view

Numbers are rounded to 2 decimals.

```json
{"turn": 7, "of": 48, "clock": {"played_s": 35.0, "left_s": 205.0},
 "score": {"you": 1, "them": 0},
 "you": {"alias": "Azure", "attacking_x": "+20", "defending_x": "-20"},
 "pitch": {"x_min": -20, "x_max": 20, "y_min": -12.5, "y_max": 12.5,
           "goal_half_width": 3.5, "your_penalty_area": "x <= -14, |y| <= 7"},
 "ball": {"pos": [3.21, -1.04], "vel": [4.1, 0.62], "speed": 4.15,
          "possession": "AZ-2", "in_your_half": false},
 "your_robots": [{"id": "AZ-1", "pos": [-16.9, 0.4], "vel": [0.2, -0.1],
                  "facing": [1.0, 0.0], "speed": 0.22, "kick_ready": true,
                  "dist_to_ball": 20.1, "last_role": "keeper"}],
 "their_robots": [{"id": "MG-1", "pos": [7.7, 2.1], "vel": [-3.0, 0.4],
                   "facing": [-0.99, 0.13], "speed": 3.03,
                   "dist_to_ball": 5.6}],
 "last_turn": {"your_kicks": 2, "their_kicks": 1, "your_shots": 1,
               "their_shots": 0, "goals": [], "possession_pct_you": 63},
 "your_last_directive": { … or null on turn 0 … }}
```

**Visible:** the whole physical state (soccer is a perfect-information sport),
the score, the clock, the turn index, the seat's own previous directive, and
last-turn event counts.

**Hidden:** the opponent's directives, roles, intents, `note`/`say` text and
prompt — never, not even after the fact; the episode seed; real player names
(a seat sees only `Azure` / `Magenta` and robot ids); the opponent's policy
kind; and the future. Spectators see all of it in the replay. That asymmetry
is deliberate.

## The directive (what a coach replies)

```json
{"note": "compact, keeper stays home",
 "robots": [{"id": "AZ-1", "role": "keeper", "intent": "hold",
             "target": [-17.0, 0.4], "pass_to": null, "kick": "auto",
             "say": "holding the arc"}]}
```

exactly three entries, one per robot.

| field | legal values | repair when violated |
| --- | --- | --- |
| `note` | string, ≤ **160 runes** | truncated to 160 runes |
| `robots` | exactly the seat's 3 robots | extras dropped; missing ids filled from last turn, else from `formation` |
| `robots[].id` | `AZ-1..3` / `MG-1..3`, case-insensitive, ≤ 8 runes | unmatched entries assigned by position |
| `robots[].role` | `keeper` `back` `wing` `striker` | → `wing` |
| `robots[].intent` | `chase` `intercept` `hold` `shoot` `pass` `clear` `press` | → `chase` |
| `robots[].target` | `[x, y]`, finite | clamped to the pitch; non-finite/missing → the robot's current position |
| `robots[].pass_to` | a *teammate* id ≠ self, or null | → null (and `pass` degrades to `shoot`) |
| `robots[].kick` | `auto` `never` | → `auto` |
| `robots[].say` | string, ≤ **48 runes** | truncated to 48 runes |

Parsing is tolerant: markdown fences are stripped, the outermost balanced
`{…}` is taken if the model prefixed prose, `robots` may be an object keyed by
id, and numeric strings are accepted for `target`. Only if no object with at
least one usable robot entry can be recovered does the **one** retry fire, and
then the `formation` fallback.

**Every string that reaches the replay is truncated on rune (codepoint)
boundaries, never bytes.** A byte-truncated multi-byte character is exactly
the bug that makes replay bytes render in a browser but fail a strict JSON
parser.

## Timing

| bound | value |
| --- | --- |
| decision turn | 150 ticks (5.0 s of sim time), 48 per match |
| first LLM attempt | 8.0 s |
| retry | 3.5 s |
| whole turn (both seats, one batch) | 12.0 s |
| player connect wait | `player_connect_timeout_seconds` (90 s) |
| engine hard stop | `wall_clock_budget_seconds` (690 s) → `reason: "deadline"` |
| final done broadcast, per seat | 3.0 s |

Both seats are queried in **one parallel batch** per turn (a single
`asyncio.gather` under a single `asyncio.wait_for`), so a match costs 48 × 12 s
of coaching at worst, not 96 × 12 s. If two more full turn budgets would
overrun the hard stop, a **budget guard** drops the rest of the match onto the
scripted layer, so the episode ends `complete`/`full_time` rather than
`deadline`.

## The results document (closed schema)

```json
{"names": ["daveey", "daveey-1"], "aliases": ["Azure", "Magenta"],
 "policy_kinds": ["llm", "scripted"], "scores": [0.667, 0.333],
 "win": [true, false], "goals": [1, 0], "reason": "complete",
 "end_rule": "full_time", "winner": 0, "final_tick": 7200, "final_turn": 48,
 "seed": 2864434397, "shots": [7, 4], "shots_on_target": [3, 1],
 "saves": [1, 3], "passes_completed": [9, 5], "interceptions": [4, 6],
 "possession_ticks": [4120, 3080],
 "distance_m": [211.4, 340.2, 298.7, 205.9, 318.0, 331.6],
 "llm_turns": [48, 0], "fallback_turns": [0, 0],
 "fallback_causes": [{"timeout": 0, "parse_error": 0, "transport_error": 0,
                      "no_credentials": 0, "budget_guard": 0}, {}]}
```

`score(seat) = 0.5 + 0.5 · clamp(goal_difference / 3, −1, +1)`, and the two
seats always sum to exactly 1.0. `reason` is one of `complete`, `deadline`,
`fault`; `end_rule` carries the detail (`full_time`, `mercy`, `wall_clock`,
`sim_fault`, `host_error`).

## The replay

UTF-8 JSON, `protocol: "cogball/v1"`. `seed` + `first_kickoff_seat` +
`controls_b64` (tick_count × 18 bytes of quantised `(thrust i8, turn i8,
kick u8)` per robot) + the pinned physics core reproduce the episode exactly.
`keyframes` carry the state digest every 30 ticks so a re-simulation can be
verified without trusting it, and `events` carry the human-readable story:
`match_start`, `turn_start`, `directive`, `fallback`, `budget_guard`, `kick`,
`touch`, `shot`, `save`, `pass_completed`, `interception`, `post`, `goal`,
`kickoff`, `turn_end`, `end`.
