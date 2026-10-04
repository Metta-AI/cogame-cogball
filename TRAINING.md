# Cogball training

The game owns acceptance, exact installed directives, robot inputs, and final scores.
Private trajectories stage every issued attempt until readers join and cleanup is acknowledged.
They retain actual native headers, byte prefixes, completion flags, and received identities.
They never enter spectator replay records or the player Docker image.

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
coworld training export /tmp/cogball-corpus/trajectories.jsonl /tmp/cogball-qualified --transport local
python -m metta_posttrain.cli export-hosted --source /tmp/cogball-qualified/episodes.jsonl --output /tmp/cogball-dataset --authority /absolute/path/external-review-authority.json
```

The shared importer splits by `cogball-<seed>` across variants and retains
`text_action` metadata. Exported content remains unreviewed until content-bound review.
Local teacher and HTTP fixture qualification does not establish real hosted archive
joins, checkpoint model quality, or reinforcement-learning qualification.

`tools/train_bridge.nim MANIFEST VARIANT --language [OPERATOR_PROMPT]` renders the
same structured prompt and uses the hosted parser and two-attempt fallback budget.
A first rejection returns the exact next prompt; a second consumes the formation
fallback and emits `consumed_rejection`, excluding the invalid response from labels.
The default bridge invocation remains a separate 345-choice numeric research task.
