# Experimental Polyworld replay slice

This is a native and browser presentation experiment, not a replacement for the
hosted Cogball viewer. It consumes the original COWLDBAL codec and recorded six robot
masks through Cogball's unchanged replay runtime. Two policy seats still own
three robots each. No control, physics, game version, golden or vendor pin changes.

The value snapshot contains only current tick, phase, score, six robot positions
and headings, and ball position. It has no references into the simulation and no
coach directives, note/say, policy names, seed, training or provider data. The
scene uses the actual `polyworld/shapes` API, with robot and ball sizes derived
from Cogball constants. Rendering floats never feed back into authority state.

## Reproduce

The tested source pair is Cogball `4399c79276a724dce34a820c59ce261731159ffe`
and Polyworld `449ad184052567c30fa54c269ef45ff8c9e8e29b`. Supply the latter as
a read-only source path; there is deliberately no new vendor/submodule pin.
Resolve game dependencies from the existing `nimby.lock`, including Bitworld
`23e8eb83d831611c80ca35ea63b53cc968308e2f`. Add those resolved `src` directories
as `--path` flags to every Nim invocation below, plus `--path:src` and
`--path:<polyworld checkout>/src`. Do not borrow an ancestor's package resolution.

Use one compiler worker and CPU at a time, under the host's resource queue and
memory guards. The local proof used installed Nim 2.2.10 and Emscripten 5.0.7;
it does not certify the release image's Nim 2.2.4 / Emscripten 4.0.15 toolchain.
Keep binaries, caches, traces and frames in a private evidence directory.

1. Compile `proof.nim` with `--skipParentCfg:on -d:release --parallelBuild:1`
   and the dependency paths above. Run it from the game root:

   ```sh
   native-proof tests/fixtures/cogball-679961.bitreplay trace.jsonl summary.json
   ```

   This checks every recorded hash, whole serialized-state invariance around
   snapshot construction, goal/kickoff seeks, private sentinel exclusion and
   rejection of an authored corrupted hash. It never records a new episode.

2. Compile the **existing** `replay-viewer/cogball_replay.nim` with
   `--skipParentCfg:on -d:emscripten -d:cogballPolyworldProof --parallelBuild:1`
   and the same dependency paths. Preserve its existing exported functions and
   append `_cogball_proof_state,_cogball_proof_step,_cogball_proof_seek,`
   `_cogball_proof_reset` to `EXPORTED_FUNCTIONS` using `--passL`.
   The production build does not define this flag or expose these probes.

   ```sh
   node experiments/polyworld_replay/compare_wasm.cjs replay-viewer/dist \
     tests/fixtures/cogball-679961.bitreplay trace.jsonl summary.json
   ```

   The comparator uses decimal strings for uint64 hashes. It checks the original
   public viewer frame/packet path, every tick and all seeks against native state,
   and rejects an authored wrong expected hash.

3. Compile `render.nim` with the native flags and paths from step 1, except
   use Shady `c899f7cd17dbe7021d6e3aa2908e6de6549c47f1` from Polyworld's
   lock for this renderer build. Cogball's pinned Shady lacks `glsl4Desktop`,
   so it cannot compile current Polyworld shapes. Resolve this revision in a
   private checkout and replace the Shady search path only for the renderer;
   leave both dependency locks and shared caches unchanged. Run a
   bounded software-rendered scene, supplying a retained goal/kickoff tick:

   ```sh
   LIBGL_ALWAYS_SOFTWARE=1 LP_NUM_THREADS=1 xvfb-run -a \
     render-proof tests/fixtures/cogball-679961.bitreplay 639 frame.png frame.json
   ```

   It requires llvmpipe/softpipe, captures the actual framebuffer, and verifies
   unchanged serialized authority after three actual Polyworld draw passes.
   Compare its state sidecar with that tick in the native trace, then inspect the
   frame for three robots of each team, the ball and the recorded score.

4. For the bounded browser adapter, first compile `export_browser_replay.nim`
   with step 1's native flags and dependency paths. This allowlists simulation
   config, anonymizes joins and drops chat, debug and client-input records. It
   refuses to qualify the export unless every public state and recorded hash
   matches the original. The committed input fixture remains unchanged.

   ```sh
   public-export tests/fixtures/cogball-679961.bitreplay /private/public.bitreplay
   ```

   Create a private `static` output directory and copy `browser/index.html` and
   `browser/replay.js` there. Compile `browser/entry.nim` with
   `--skipParentCfg:on -d:emscripten --parallelBuild:1` and step 3's dependency
   paths, setting `COGBALL_BROWSER_OUTPUT` to that directory and
   `COGBALL_BROWSER_REPLAY` to the qualified public replay. Its local config
   packages only game art/fonts and that public replay, caps WASM memory at
   256 MiB and requests WebGL2. The entry uses the same live-runtime exit as the
   shipped viewer so Nim globals survive later exported JavaScript calls.

   Serve only the five emitted static resources on loopback; keep the original
   fixture, native oracle, caches and logs outside the served directory. Under
   the unchanged host FIFO, use one isolated installed agent-browser session
   with CPU/softwareGL, one CPU and finite runtime/memory/zero-swap bounds.
   Exercise Play/Pause, tick Seek and viewport resize. Compare browser state
   and decimal-string hashes with the native trace; retain actual screenshots
   and binary/toolchain identities privately. No new dependencies are required.

## Executed decision and limits

The committed 48,288-byte fixture (Git blob
`855adaeecb7227544a01652c4c47e79f6b929376`) contains goals at ticks 638 and
1128 and ends 1–1. Native/WASM parity passed for ticks 0–1352 and ten seeks.
The value snapshot and actual software-rendered scene preserve authority.
This supports proceeding with a **planar replay presentation prototype** while
keeping Cogball's custom integer simulation and codec.

The browser followup also passed ten seeks against native state, actual Play /
Pause from tick 1127 through 1129, and resize from a 960×720 canvas to 360×640.
Thirty explicit Polyworld draws preserve the whole serialized authority state;
resize and playback pause preserve the expected public state. Actual WebGL2
framebuffer readback and two screenshots show the six robots, ball and 0–1 / 1–1
scores. The measured backend was ANGLE SwiftShader. Private sentinels were
excluded and an authored corrupted recorded hash was rejected without changing
the active replay. All 1,353 states match after removing 23 original strategy
records from the browser input. The entire owned FIFO session, including compilation,
readback and browser/server cleanup, stayed within 20 minutes, with a 2 GiB
cgroup memory limit and zero swap.

This does not establish a full game migration, hosted integration, asset/UI
parity, private coaching UI or graphics speedup. This browser entry binds its tick
controls to the retained 0–1352 fixture and advances one tick per presentation
interval; it does not reproduce the original viewer's speed, lull, loop or timing
controls. The narrow viewport fits the pitch with letterboxing; its simple status
line can overflow horizontally. Public replay resources necessarily include the
recorded input sequence and simulation seed, while the exported current-state
payload excludes them. The export proof qualifies this fixture; arbitrary replays
must pass the same equality check before use. The primitive prototype omits original robot art, broadcast chrome and goal FX.
The score display supports 0–9 and rejects larger scores. Polyworld's shapes
apply their existing half-alpha tint; colors are not claimed to match the old
viewer. The engine lock differs from the game's dependency lock: this slice
tests the shapes API against Cogball's exact dependencies, not the whole engine
dependency graph. Reconciling those Shady versions is a blocker for sharing one
production build configuration. Detailed measurements and images remain private.

## Release-input qualification (2026-10-04)

The documented release configuration is Nim **2.2.4** (`Dockerfile:25`) and
Emscripten **4.0.15** (`Dockerfile.replay-viewer:4`). Fresh source and retained
cache inspection found only Nim 2.2.10 and Emscripten 5.0.7 on the proof host.
The bounded release-input gate exits 78 before compilation; release compilation
and native/WASM parity under those required versions remain **unqualified**.
The earlier browser receipt is retained, rather than rerun or relabeled.

The dependency mismatch is exact: Cogball's locked Shady
`c89db58632c5442df16251b3e15cb43c5d52e2a6` exports `glslDesktop` / `glslES3`;
Polyworld shapes at `449ad184052567c30fa54c269ef45ff8c9e8e29b` require
`glsl4Desktop` / `glsl3WebGL`. The isolated Shady
`c899f7cd17dbe7021d6e3aa2908e6de6549c47f1` exports those targets and legacy
aliases, and is the exact override used in the earlier passing adapter proof.
That receipt does not establish compatibility under the missing release tools
or qualify a production lock update. Both dependency locks remain unchanged.

Resumption requires retained Nim 2.2.4 (including its matching library/config)
and a complete retained Emscripten 4.0.15 SDK, with identities and a finite
SDK/scratch byte budget before build admission. At readback the host had only
132,440,064 bytes free on the shared home/tmp filesystem; source/evidence work
was admitted with a 1 MiB budget. No release build, dependency installation,
image download, browser run or shared cleanup was performed. The private
release result retains the input-gate reproducer, available compiler hashes,
source bindings and terminal FIFO receipts.
