# Cogball training

The game owns acceptance, exact installed directives, robot inputs, and final scores.
Private trajectories stage every issued attempt until readers join and cleanup is acknowledged.
They retain actual native headers, byte prefixes, completion flags, and received identities.
They never enter spectator replay records or the player Docker image.

A complete native match can publish public outcomes while its private cleanup
status remains truncated. Missing acknowledgements never become completed private
evidence. Replay/events precede a bounded private finalization attempt; results
come last under the original five-second deadline, with 500 ms reserved for them.
Private upload failure leaves an explicit unconfirmed-publication gap even if its
attempted payload had been sealed. Neither public success nor an unacknowledged
or unpublished private payload establishes admission. Finalization stage timings
are logged; CPU serialization and local filesystem work are not preempted.

Set `COGAME_SAVE_TRAJECTORY_URI`, `COWORLD_EPISODE_ID`, `COWORLD_GAME_VERSION`, and
`COWORLD_SOURCE_REVISION` on the game. Runtime injection also supplies the registered
`COWORLD_GAME_NAME` and immutable `COWORLD_GAME_IMAGE_DIGEST`. Production provenance must identify the actual
published version and immutable source. Deploy the shared runtime injection before
publishing this source as a Coworld.

Players retain actual `X-Softmax-Llm-Call-Id` and checkpoint/tokenizer/template headers.
They transmit these privately as `training_attempt`. The game rejects model evidence
whose response does not independently parse to the submitted directive. Player
assertions of teacher/human origin become unknown. Only intentional engine-owned
scripted policies produce teacher labels; no-shows and failed inference remain fallback.
Set `COWORLD_LLM_TEMPERATURE=0` for greedy checkpoints or `1` for qualified native
sampling. Token IDs and behavior probabilities are retained only when actually provided.

The formation/swarm policies read the same rounded positions the coach observes.
Teacher export and language resets advance the actual lobby countdown before observing play.
Their opening interval ends at the same absolute turn boundary as the hosted engine.
Teacher export consumes the authoritative private JSON view. Exact target coordinates
remain in private applied actions; spectator coordinates retain display rounding.

Each decision records `observation.execution`: exclusive start/end ticks, 24 Hz,
three unsigned Sprite masks per seat per tick, and the actual per-tick hash chain.
This is Cogball's `sprite-three-u8` encoding. It is not the four-byte motor-control
encoding used by other games. Validate it against the binary replay:

```bash
nim c -d:release --path:src -o:/tmp/cogball-replay-check tools/check_training_replay.nim
/tmp/cogball-replay-check replay.bitreplay trajectory.jsonl
```

Use the reviewed Metta SDK and application importer for these commands.
The publishing CLI version does not establish training-consumer qualification.
Scripted teacher exports use `source-engine-1`, with the rules version recorded separately.
All serving fields are null; teacher targets require external, content-bound authority.

Export raw complete teacher episodes, then use the shared dataset path:

```bash
nim c -d:release --path:src -o:/tmp/cogball-export tools/export_posttrain.nim
/tmp/cogball-export /tmp/cogball-corpus 20 1 default
```

From the shared Metta checkout, validate and convert the raw event stream:

```bash
uv run --package coworld python - <<'PYTHON'
from pathlib import Path
from coworld.decision_trajectory import export_complete_episodes, read_trajectory_jsonl

source = Path("/tmp/cogball-corpus/trajectories.jsonl")
destination = source.parent / "complete-episodes.jsonl"
assert export_complete_episodes(read_trajectory_jsonl(source), destination) == 20
PYTHON
```

The shared `metta_training.posttrain.hosted.export_hosted` importer requires
external authority bound to the complete-episode SHA256 and exact source revision.
Conversion does not grant approval. Select `scripted-formation` explicitly.
The importer splits by `cogball-<seed>` across variants and retains
`text_action` metadata. Exported content remains unreviewed until content-bound review.
Local teacher and HTTP fixture qualification does not establish real hosted archive
joins, checkpoint model quality, or reinforcement-learning qualification.

`tools/train_bridge.nim MANIFEST VARIANT --language [OPERATOR_PROMPT]` renders the
same structured prompt and uses the hosted parser and two-attempt fallback budget.
A first rejection returns the exact next prompt; a second consumes the formation
fallback and emits `consumed_rejection`, excluding the invalid response from labels.
The default bridge invocation remains a separate 345-choice numeric research task.

## Prompt diversity

Set `promptVariant` to `canonical`, `plain`, `numbered`, `questions`, or
`reordered`; `mixed` requires a nonnegative `promptSeed` and selects seed modulo
five. The game owns selection for the whole episode, both seats, and retries.
`heldout-briefing` and `heldout-reference` are evaluation-only; training resets
and source export reject them. The numeric bridge remains canonical.

Language resets accept the same keys and `split` (`train` by default).
Use `validation` or `test` for held-out wording. Selected message hashes live outside
the model view. Private hosted captures retain the bank, selection, and seed,
plus hashes for actual model and teacher attempts after late evidence joins.
No prompt selector enters simulation state or public replay.

The source exporter accepts `OUTPUT EPISODES FIRST_SEED VARIANT PROMPT_VARIANT
PROMPT_SEED`. Mixed exports advance the prompt seed per game and record each
selection. Collect matched seeds in separate output directories for each
wording. Episode IDs include wording; seed-family IDs do not, so the shared
importer keeps all variants of a scenario in one split. Commit source first.
Teacher corpora remain candidates requiring external content-bound review.

For frozen-model evaluation, compare canonical and both held-out wordings on
matched seeds, seats, opponents, and ordinary match budgets. Report scores,
invalid replies, fallbacks, and completion rates. Scripted parity verifies
mechanics; it does not establish better learning or reduced collapse.

Run `python3 tools/test_prompt_variants.py BRIDGE_BINARY` for 16 complete
language matches across both published variants, seven direct wordings and one
mixed selection. Checks cover exact prompt hashes, private coach views, actions,
outcomes and rejection of held-out training selections. The existing native
trajectory fixture now verifies mixed wording on real player requests while
retaining attempt, fallback and physical execution checks. The duplicate native
wording panel is removed.
