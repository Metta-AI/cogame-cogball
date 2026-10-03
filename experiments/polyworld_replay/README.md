# Experimental Polyworld replay slice

This is a native presentation experiment, not a replacement for the hosted
Cogball viewer. It consumes the original COWLDBAL codec and recorded six robot
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

## Executed decision and limits

The committed 48,288-byte fixture (Git blob
`855adaeecb7227544a01652c4c47e79f6b929376`) contains goals at ticks 638 and
1128 and ends 1–1. Native/WASM parity passed for ticks 0–1352 and ten seeks.
The value snapshot and actual software-rendered scene preserve authority.
This supports proceeding with a **planar replay presentation prototype** while
keeping Cogball's custom integer simulation and codec.

It does not establish a full game migration, browser WebGL adapter, hosted
integration, asset/UI parity, private coaching UI or graphics speedup. The
primitive prototype omits original robot art, broadcast chrome and goal FX.
The score display supports 0–9 and rejects larger scores. Polyworld's shapes
apply their existing half-alpha tint; colors are not claimed to match the old
viewer. The engine lock differs from the game's dependency lock: this slice
tests the shapes API against Cogball's exact dependencies, not the whole engine
dependency graph. Reconciling those Shady versions is a blocker for sharing one
production build configuration. Detailed measurements and images remain private.
