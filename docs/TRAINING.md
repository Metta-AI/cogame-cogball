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
