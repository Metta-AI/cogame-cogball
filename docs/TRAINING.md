# Metta post-training data

The exporter uses Cogball's maintained native simulator and published
`formation` baseline. At each turn it records both seats' exact player-visible
view, the hosted system prompt, and a reply validated by the production
directive parser. The same turn engine and control layer then play the full
match. Both certified variants are supported.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/cogball-export-posttrain tools/export_posttrain.nim
/tmp/cogball-export-posttrain /tmp/cogball-default-dataset 10 1 default
/tmp/cogball-export-posttrain /tmp/cogball-sprint-dataset 10 1 sprint
```

The output has `train.jsonl`, `validation.jsonl`, and `manifest.json`. Games
with seeds divisible by five are validation games. The exporter requires at
least ten complete games and refuses to overwrite existing data.

From a Metta checkout with the post-training package installed, train on an
exported dataset:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/cogball-default-dataset \
  --output /tmp/cogball-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

The ten-game local proof exported 640 train and 160 validation examples for
default, and 320 train and 80 validation examples for sprint. All fit a
4,096-token context. One CPU optimizer step reduced four-example validation
loss from 1.69949 to 1.69358 for default and from 1.69949 to 1.69357 for
sprint. These checks validate the data and optimizer paths; they do not show
that a trained policy plays better than `formation`.

# Numeric training

The numeric bridge runs the shipped match simulator and controller, including
both seats' simultaneous coaching turns. Each decision carries the exact
hosted coach view as `semantic_view` and 87 fixed numeric features. Its 345
choices are the `formation` and `swarm` scripted baselines plus every
combination of seven intents for the three robots, using formation targets.
The chosen reply passes through the production directive parser. The catalog
does not expose arbitrary target coordinates or every possible directive.

```sh
nim c -d:release --path:src -o:/tmp/cogball-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/cogball-train-bridge
```

With a Metta checkout containing the generic Coworld bridge, pass
`[/tmp/cogball-train-bridge, /absolute/path/coworld_manifest_template.json,
default]` to `recipes.external.coworld_metta_rl.train` or
`recipes.external.coworld.train` for native PufferLib. Use `sprint` for the
second certified variant, set `players=2`, and choose a finite timestep limit.
Full teacher and random matches completed for both variants; observations
stayed frozen until both coaches acted.

Metta RL completed 512 training steps and evaluation for each variant. The
mean evaluation returns were -0.333 for default and 0.500 for sprint. Native
PufferLib completed 4,096 CUDA training steps, checkpoint reload, and eight
held-out games per variant. Default scores were 625 and 208.25 on seeds 101
and 102 (checkpoint SHA-256 `9c94a0b116e813d03d6790fd809a083b5ac3c3f486f1066ef8a38232380d6116`).
Sprint scores were 583.5 and 625.25 (checkpoint SHA-256
`6d5d275a62cc1ce167a5bb896df7abdc2ea90becd5d2c57aedc43b0912d5199d`).
These pilots verify the training and evaluation paths, not league strength.
