# cogball

**3v3 robot soccer in a continuous 2D physics world.** Two teams of three wheeled robots chase
one ball on a walled indoor pitch and try to push it over the opponent's goal line. Nothing is
gridded: positions, velocities and headings are IEEE doubles; the only discrete things in the
world are the tick and the kick.

Cogball is a Coworld. A policy is just a prompt: every 5 seconds of match time a coach — an LLM,
or one of two scripted baselines — issues **one directive** for all three of its robots (a role, a
target point, an intent and a kick policy each), and a deterministic control layer executes it at
30 Hz. The coach is the tactics; the control layer is the reflexes.

```
Seats            2 (num_agents = 2). One seat = one full trio.
                 Seat 0 Azure  (AZ-1..3) defends x = -20, attacks +x
                 Seat 1 Magenta (MG-1..3) defends x = +20, attacks -x
Pitch            x in [-20, +20], y in [-12.5, +12.5]; goal mouths |y| <= 3.5 at x = +-20
Time             30 ticks/s, 4 physics substeps per tick, 7200 ticks = 4:00 of soccer
Turns            48 decision turns of 150 ticks (5.0 s)
Motive           team zero-sum: score(seat) = 0.5 + 0.5 * clamp(goal_difference / 3, -1, +1)
                 so the two seats' scores always sum to exactly 1.0
```

## How a match plays

At the start of each turn the server freezes the world, sends each seat its view (the complete
physical state — soccer is a perfect-information sport — plus the score, the clock and its own
last directive), and asks both coaches **in one parallel batch** what to do. Each reply is a
single JSON object:

```json
{"note": "compact, keeper stays home",
 "robots": [{"id": "AZ-1", "role": "keeper", "intent": "hold", "target": [-17.0, 0.4],
             "pass_to": null, "kick": "auto", "say": "holding the arc"}, "... and two more"]}
```

Intents are `chase`, `intercept`, `hold`, `shoot`, `pass`, `clear` and `press`. The control layer
turns each one into a steering point, then into thrust and turn commands: robots are car-like, so
lateral velocity is scrubbed off by grip and **facing the right way is part of the skill**.

A reply that is late, malformed or unusable is retried once and then replaced by the `formation`
baseline's directive — the match never stalls waiting for a coach.

## Policies

One image, switched by environment variable:

| env | what the seat plays |
| --- | --- |
| `PLAYER_PROMPT=<strategy text>` | an LLM coach; the prompt *is* the policy |
| `PLAYER_SCRIPTED=formation` | keeper on the arc, striker on the ball, third robot shuttling |
| `PLAYER_SCRIPTED=swarm` | everyone chases; deliberately weaker |
| neither | `formation` |

Both shipped champions (`cogball-total`, `cogball-counter`) are prompt policies.
`docs/COACHING.md` is the guide to writing one.

## Determinism and replays

The physics core (`sim/cogball_core.c`, ~400 lines of C99) uses **only `+ - * / sqrt`** on
doubles — no libm, no `float`, no `-ffast-math`. WebAssembly specifies those operations exactly
and forbids contraction, so the server build (wasmtime, standalone wasm) and the browser build
(emscripten) produce **bit-identical** state. That is what lets a replay be nothing more than a
seed plus an action log:

```
replay = {seed, first_kickoff_seat, controls_b64, keyframes[…digests…], events[…], results}
```

`tests/test_determinism.py` is the inviolable gate: identical digests at every 30-tick keyframe,
across both toolchains. If it fails, the physics or a build flag changed — fix the code, never
the test.

The replay viewer is a **static wasm bundle** (`viewer/`), built from the same C source by
`tools/build_replay_viewer.sh`. It re-simulates in the browser and draws the pitch, the robots,
ball trails, kick rings, goal fireworks, an instant slow-motion goal replay, and a persistent
position-history heat trail per robot — over four minutes the keeper's arc, the back's shuttle
and the striker's runs separate visually, so you can see roles emerge with no labels on screen.

## Layout

```
sim/            cogball_core.{c,h}, cogball_config.h, viewer_main.c, build_sim.sh, build_viewer.sh
server/cogball/ server.py engine.py sim.py control.py directives.py baselines.py llm.py
                replay.py config.py defaults.py uris.py
players/        cogball_player.py    (register once, then watch)
viewer/         index.html, static_replay.js  -> viewer/dist (wasm bundle)
tests/          physics, determinism, control, baselines, llm parsing, engine, replay,
                server, manifest, viewer, startup, perf
tools/          build_replay_viewer.sh, ci/docker_smoke.sh, ci/policies.json
docs/           PROTOCOL.md, COACHING.md, plans/
```

## Build and test

```sh
bash sim/build_sim.sh       # -> build/cogball_sim.wasm      (wasmtime host)
bash sim/build_viewer.sh    # -> viewer/dist/ + build/viewer_core.{js,wasm}
uv sync && uv run pytest
```

Both build scripts need emscripten; the viewer build also downloads the sha-pinned raylib 5.5 web
release. CI (`.github/workflows/ci.yml`) runs all of it, plus a raw-Docker episode smoke and the
static replay-viewer bundle build.
