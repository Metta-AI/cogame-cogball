# cogball

**3v3 robot soccer in a continuous 2D physics world.** Two teams of three
wheeled robots chase one ball on a walled 40 × 25 m indoor pitch and try to put
it through the opponent's goal mouth. Nothing is gridded: positions and
velocities are continuous fixed-point quantities, and the only discrete things
in the world are the tick, the actuator bits and the kick.

**A policy is just a prompt.** A seat does not drive motors. Every five seconds
of match time it issues ONE directive for all three of its robots — a role, an
intent, a target point and a kick permission each — and a deterministic control
layer executes it for the next five seconds. Forty turns, one directive each.
Passing, positioning and role emergence are the whole game.

```
                 +20 m
   AZURE  ┌───────────────────────┐  CRIMSON
   goal  ▐│    ·   AZ-2      CR-1 │▌  goal
         ▐│  AZ-1    (o)          │▌
         ▐│         CR-3   AZ-3   │▌
          └───────────────────────┘
                 −20 m
```

* [docs/RULES.md](docs/RULES.md) — the pitch, the physics, the resolution
  order, the scoring and the determinism contract.
* [docs/PROTOCOL.md](docs/PROTOCOL.md) — the runtime contract, the seat
  protocol, the `COWLDBAL` replay bytes and the results document.
* [docs/COACHING.md](docs/COACHING.md) — how to write a cogball prompt.

## Seats and scoring

`num_agents` is **2**: one seat is one full trio. Seat 0 is **Azure**
(`AZ-1..3`), seat 1 is **Crimson** (`CR-1..3`). Team zero-sum and
margin-sensitive, always summing to 1.0:

```
score(seat) = 0.5 + 0.5 · clamp((goals_you − goals_them) / 3, −1, +1)
```

3–0 or better = 1.000; 1–0 = 0.667; any draw = 0.500. Higher is better.

## Playing

One image, two entrypoints, every policy env-switched:

```bash
# the game
docker run --rm -e COGAME_CONFIG_URI=file:///coworld/config.json \
  coworld-cogball:latest /bin/cogball

# an LLM seat
docker run --rm -e COWORLD_PLAYER_WS_URL=ws://game:8080/player?slot=0 \
  -e PLAYER_PROMPT="Play total football: never leave your own goal empty…" \
  coworld-cogball:latest /bin/cogball-player

# a scripted seat
docker run --rm -e COWORLD_PLAYER_WS_URL=ws://game:8080/player?slot=1 \
  -e PLAYER_SCRIPTED=formation \
  coworld-cogball:latest /bin/cogball-player
```

`formation` is the reference baseline (one keeper on the arc, the nearest robot
on the ball, the third in the channel) and also the fallback whenever a coaching
call fails twice. `swarm` is the second filler — everyone chases — deliberately
weaker, so the ladder has a spread.

## Watching

The replay ships as a **static wasm bundle**, never a pod:
`tools/build_replay_viewer.sh` builds `replay-viewer/cogball_replay.nim` — which
imports the **same** `src/cogball/sim.nim` the native server ran — through the
pinned `emscripten/emsdk:4.0.15` container, and the browser re-simulates the
recorded action log and checks the recorded `gameHash` every tick.

The broadcast chrome shows: the score bug (goals, possession, shots), the clock
and coaching turn, a plain-language match feed carrying the coaches' own notes,
a ball trail tinted by the last toucher, kick rings, a goal celebration, an
**instant slow-mo goal replay**, and position-history turf paint — each robot
paints the ground it drives over in its own hue, so over 3:20 the keeper's arc,
the back's shuttle and the striker's runs separate visually, with no labels.

## Layout

```
src/cogball.nim              game entrypoint (seed randomisation lives here)
src/cogball_player.nim       every policy: registers, then idles
src/cogball/
  sim_types.nim              consts (incl. GameVersion), types, wire format
  trig.nim                   the committed SinQ12 table, isqrt, bradsOfVectorI
  pitch.nim                  geometry, collision half-planes, the goal test
  sim.nim                    the integer physics core and the step loop
  control.nim                directive -> six actuator masks (integer only)
  directives.nim             view coordinates, rune truncation, the parser
  baselines.nim              the formation and swarm scripted policies
  llm.nim                    the credential ladder and transport
  decide.nim                 the turn engine: one parallel batch per turn
  server.nim                 mummy HTTP/ws, the COGAME_* contract, the loop
  replays.nim                the COWLDBAL codec, keyframes, the scan
  global.nim                 the board renderer
  broadcast.nim              the chrome JSON channel and the record fold-back
replay-viewer/               the emscripten entry points and the worker
client/                      the broadcast chrome (kept from paintbot)
tools/                       build hooks, forensics, CI helpers
tests/                       the determinism gate and eleven suites around it
```

## Building and testing

The repo builds with [nimby](https://github.com/treeform/nimby):

```bash
nimby --global sync nimby.lock
nim r --path:src tests/test_determinism.nim
```

CI runs every `tests/*.nim` twice — debug (range and overflow checks) and
`-d:release` — plus a raw-Docker episode smoke and the wasm bundle build with
the native↔wasm determinism gate. See `.github/workflows/ci.yml`.

Design notes live in `docs/plans/`. The lineage is
[`Metta-AI/coworld-ctf`](https://github.com/Metta-AI/coworld-ctf) (paintbot):
the game loop, the per-tick replays, the static wasm viewer, the broadcast
chrome and the CI wiring are its, kept; the physics replaces the arena rules.
