# Working in this repo

Conventions for agents (and humans) changing cogball. The design note this
repo implements is `docs/plans/2026-08-22-cogball-design.md`; read it before
changing anything about the physics, the protocol or the packaging.

## The inviolable rule

**`tests/test_determinism.py` is the gate.** It proves that the standalone
build of the physics core (wasmtime, what the server runs) and the emscripten
build (node/browser, what the replay viewer runs) produce **bit-identical**
state at every 30-tick keyframe, and that a committed golden fixture still
holds. If it fails, the physics or a build flag changed — fix the code, never
the test. Weakening or skipping it is a failed task, not a passing build.

What makes that guarantee true, and what you must not break:

- `sim/cogball_core.c` uses **only `+ - * / sqrt`** on doubles, comparisons
  and integer ops. No libm (`sin`, `cos`, `atan2`, `pow`, `fmod`, `hypot`, …),
  no `float`, no `-ffast-math` in either build script. WebAssembly specifies
  those operations exactly and forbids contraction; libm is not specified at
  all. A source guard in the gate enforces this.
- Heading rotation is **defined** as first-order rotate + renormalise. It is
  not an approximation of a trig call, so there is nothing for it to drift
  from. Do not "fix" it into `sin`/`cos`.
- The control layer lives in Python and is **not** inside the determinism
  boundary: its output is quantised to `(int8 thrust, int8 turn, uint8 kick)`
  before it reaches the sim, and those bytes are what the replay stores. The
  viewer therefore never runs the control layer at all. Keep it that way — a
  reimplementation of the control layer in the viewer is the bug class this
  design exists to remove.
- Regenerating `tests/data/golden_digests.json` is allowed only when a physics
  or control-layer change is **intended**, and the commit message must say so.

## Where things live

- Physics constants: `sim/cogball_config.h`, shared by the sim build and the
  viewer build so they can never drift. A few are mirrored into
  `server/cogball/defaults.py` for the control layer and the per-seat view;
  `tests/test_control.py` asserts the two agree.
- Server-contract defaults (`max_ticks`, `turn_ticks`, deadlines, caps, seat
  topology): `server/cogball/defaults.py`.
- Results keys are a **CLOSED schema**: `server/cogball/server.py`
  `results_document`, the manifest `results_schema` and
  `tools/ci/docker_smoke.sh`'s expectations must be edited in the same commit.
  `tests/test_manifest.py` compares the first two key-for-key.
- `game.docs` in the manifest inlines `README.md`, `docs/PROTOCOL.md` and
  `docs/COACHING.md` as **text** (the platform's URI form leaves the coworld
  page empty). Edit a doc, re-inline it; `tests/test_manifest.py` compares
  first lines and will catch a stale copy.

## Two name spaces

Coaches see `Azure` / `Magenta` and robot ids `AZ-1..3` / `MG-1..3` — never a
real player name, never the opponent's directives, roles, `note` or `say`.
Real names appear only spectator-side: the replay's `names.players`, the
results document, and the viewer scorebug. Both, not either.

## Degrade, never hang

The game container is not told the platform's episode timeout; assume 1200 s
and settle inside 60 % of it. Every wait is bounded: per-attempt LLM
deadlines (8.0 s then 3.5 s), one `asyncio.wait_for` per turn (12 s), the
connect timeout, the 3 s done-send timeout, and the engine's 690 s hard stop.
Both seats' coaching calls go out as **one parallel batch** per turn — never
sequentially; that is what keeps 48 turns inside the budget.

## Build pipeline

```sh
bash sim/build_sim.sh       # -> build/cogball_sim.wasm       (wasmtime host)
bash sim/build_viewer.sh    # -> viewer/dist/ + build/viewer_core.{js,wasm}
uv sync && uv run pytest
```

`build/`, `dist/` and `viewer/dist/` are gitignored build outputs. The
Dockerfile runs both scripts in its `wasm-builder` stage; the emcc pin (6.0.5)
and the raylib sha must stay in sync across `Dockerfile`,
`sim/build_viewer.sh` and `.github/workflows/ci.yml`.

## Testing and review discipline

- `uv run pytest` runs the full suite (slow-marked tests included in CI).
  Run it before every commit that touches sim/server/players.
- TDD for behaviour changes: failing test first, then the implementation.
- Commit in small, single-purpose units with pathspec `git add`.
- Packaging changes (Dockerfile, compose, manifest template) must keep
  `docker build` + `tools/ci/docker_smoke.sh` and `coworld build` +
  `coworld certify` green. The sandbox has no Docker or emsdk — CI is the
  only harness.
- `tools/ci/docker_smoke.sh` and `tools/build_replay_viewer.sh` must stay
  **executable** (`git update-index --chmod=+x`): `coworld build` refuses to
  package the replay-viewer bundle unless the hook is `os.X_OK`.

## Coworld platform contract

The server implements the `COGAME_*` runtime contract, `/player` + `/global`
websockets, `/client/*` pages and replay mode — see `docs/PROTOCOL.md`. The
manifest declares a **static** replay-viewer bundle
(`{"bundle": "static-replay-viewer"}`), built by
`tools/build_replay_viewer.sh` from the Dockerfile's `wasm-builder` stage. A
pod-served `/client/replay` viewer is never acceptable as the declared viewer;
the server still serves that route for local viewing only.

Releases go through `.github/workflows/coworld-release.yml`
(`workflow_dispatch`): build → certify → upload policies → upload the Coworld
→ put the secret. The order is load-bearing; do not reorder it.
