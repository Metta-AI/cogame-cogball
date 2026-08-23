# Agent operating guide — cogame-cogball

Orientation for coding agents working in this repo. Gameplay rules live in
[docs/RULES.md](docs/RULES.md); the wire is in
[docs/PROTOCOL.md](docs/PROTOCOL.md); this file covers the workflows that are
easy to get wrong.

The lineage is `Metta-AI/coworld-ctf` (paintbot). Its game loop, per-tick
replays, static wasm viewer, broadcast chrome and CI wiring are kept; cogball's
physics replaces the arena rules. When a convention here is unexplained, look at
paintbot first — it is probably the same convention.

## The determinism gate is the inviolable test

`tests/test_determinism.nim` plus the `wasm-viewer` CI job are one gate in two
halves. **If it fails, the physics or a build flag changed — fix the code,
never the test.**

Concretely, four rules hold in
`src/cogball/{sim,sim_types,sim_config,sim_state,pitch,control,trig}.nim`:

1. **No bare `int` in stored sim state.** Nim's `int` is 64-bit natively and
   32-bit under `--cpu:wasm32`, and the same module compiles both ways — the
   native server records, the emscripten viewer re-simulates. Every hashed
   field is an explicit `int32` / `bool` / enum.
2. **Every product or quotient of two sim quantities is taken in `int64`** and
   narrowed with an explicit truncating `div`. Nim's `div` truncates toward
   zero, so the arithmetic is symmetric under negation — which is what makes
   the two ends of the pitch exactly fair. `test_physics.nim` pins that.
3. **No floating point, and no libm.** The guard in `test_determinism.nim`
   strips comments and string literals and then greps for `sin|cos|tan|arctan|`
   `arcsin|arccos|exp|ln|pow|sqrt|hypot|float|float32|float64` as whole
   identifiers. Rendering (`global.nim`, `rig_art.nim`, `broadcast.nim`) is
   float-friendly by design: it never enters `gameHash`. That is also why the
   pixie turf bake lives in `global.nim` and not in `pitch.nim`.
4. **Trigonometry is a committed table.** `SinQ12` in `trig.nim` is generated
   once by `tools/gen_trig_table.nim` and checked in; a test re-derives every
   entry from `math.sin`. A compile-time `const` computed from `sin()` was
   rejected: the two builds are two separate compilations, and a committed
   table removes the question.

## What is inside gameHash and what is not

`sim_state.gameHash` mixes the tick, the phase, the verdict, the score and
every body's position, velocity, heading, spin and cooldown — and nothing else.

**Outside it, deliberately:** directives, `note`/`say`, the ball trail, kick and
goal FX, the turf paint, the broadcast feed, the tier-2 event stream, and the
`lastGoal*` fields the feed reads. Those last are set INSIDE the hashed step, so
the viewer re-derives them identically; they are simply not hashed, because the
kickoff reset clears `lastTouch` and the feed still has to say who scored.

Adding a hashed field invalidates every existing replay, so it is a
`GameVersion` bump. Adding an unhashed one is free.

## A GameVersion number is claimed across BRANCHES, not just against main

Being current with `main` is not enough: two long-lived branches can each be up
to date and still pick the same next number. Before you claim one, scan the open
branches, and check it with:

```bash
tools/ci/check_gameversion.sh origin/main          # checks your working HEAD
tools/ci/check_gameversion.sh origin/main <branch> # checks another branch
```

It exits non-zero when your version reuses the base's number **for a different
rule**, and stays quiet when `GameVersion` is untouched. Note what it compares:
the number alone cannot detect a collision, because both sides read the same
digits. What distinguishes them is the RULE the number is attached to, so the
script diffs the headline on the changelog comment. Keep the
`GVnn (short rule name): HEADLINE` shape — it is prepend-only history.

## The control layer is OUTSIDE the determinism boundary

The recorded action log is the six robots' input masks. The control layer, the
LLM and the directive records are all outside it: the viewer never runs them, it
feeds the recorded masks to the identical physics core. That makes the whole
class of "the control layer was reimplemented in the viewer and drifted" bugs
structurally impossible — and it is why `control.nim` may be retuned without a
`GameVersion` bump, while `sim.nim` may not.

The corollary bites the other way too: **the sim can never read a directive.**
Pass and save attribution are derived from state alone (kick, then next touch)
for exactly this reason. If you find yourself wanting `intent` inside
`sim.nim`, you want it in `control.nim` instead.

## Layout

* `src/cogball.nim` — the entrypoint. **Seed randomisation happens HERE**,
  before `config.update`, so every seed-derived draw follows the final seed.
* `src/cogball/sim_types.nim` — consts (incl. `GameVersion`) and the flatty
  wire format. `SimServer` is serialized POSITIONALLY into replay keyframes:
  **append fields, never insert or reorder.**
* `src/cogball/server.nim` — ctf's server with four named edits, each marked in
  the file: the input source, the turn boundary, registration interception and
  the wall-clock stop.
* `src/cogball/replays.nim` — ctf's codec with two named edits: masks are
  indexed by ROBOT (six), and a leave does not shift the mask arrays.
* `tests/` — run from the repo ROOT (`nim r --path:src tests/<file>.nim`);
  assets resolve via `data/`. Use `-d:release` for anything heavy.
* Dependencies come from nimby (`nimby --global sync nimby.lock`); the
  Dockerfile is the canonical build recipe, and it regenerates `nim.cfg` from
  the container's package tree because a committed `nim.cfg` pins the author's
  machine paths and is wrong on every other host.

## Interaction radii must be derived from the art

Paintbot learned this three times on its heart pickup: a body's SIM radius and
its DRAWN size are two numbers in two modules and nothing structurally ties
them. When they disagree the game lies — the art says "you are on it", the sim
says "you are not", and there is no feedback distinguishing "not close enough"
from "this does not work".

Cogball's exposure is the kick: `KickRange` is `RobotRadius + BallRadius +
KickReach`, and the drawn robot (`RobotBodyPx`) is sized against the same
`RobotRadius`. If you touch either, check the other and assert the relationship
in `tests/test_physics.nim` rather than leaving it as prose.

## Replay fixtures

`tests/fixtures/cogball-679961.bitreplay` is recorded against the CURRENT rules
by the NATIVE build and must be re-recorded on every `GameVersion` bump. CI
records it in the `test` job (`tools/record_fixture.sh`) and hands it to the
`wasm-viewer` job as an artifact, so it is never stale relative to the code that
produced it — which is the point: the wasm smoke exists to catch a divergence
between two builds of the same source, and a fixture from an older source
proves nothing.

Recording locally needs the two binaries built first:

```bash
nim c -d:release --threads:on --mm:orc -o:bin/cogball src/cogball.nim
nim c -d:release --threads:on --mm:orc -o:bin/cogball-player src/cogball_player.nim
tools/record_fixture.sh tests/fixtures/cogball-679961.bitreplay 679961 1200
```

The script prefixes `$PWD`, so pass repo-relative output paths.

## Debugging a prod league replay

Download the bytes directly; never drive the Observatory UI. Every job's replay
is public at
`https://softmax-public.s3.amazonaws.com/replays/<job_request_id>.replay`.

```bash
curl -sSL "$replay_url" -o /tmp/ep.replay
python3 tools/replay_summary.py /tmp/ep.replay | jq .
```

`replay_summary.py` is Python-3-stdlib only — no Nim, no Docker — and reports
the protocol, the seed, the names, every directive with its source, the fallback
count and the results document. For a full re-simulation use
`parseReplayBytes` + `initReplayRuntime`, exactly like the wasm viewer.

## Two name spaces, and why

Prompts and board labels carry **only** `Azure` / `Crimson` and `AZ-1..3` /
`CR-1..3`. Real policy names appear **only** in the replay config JSON, the DOM
scorebug/roster and `results.names`. `tests/test_server.nim` enforces it: the
composed LLM user message and the player-stream board labels must contain no
`sim.players[i].address`, while the chrome roster and `results.names` must.
