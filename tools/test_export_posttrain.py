"""Check complete Cogball exports and seed-separated teacher rows."""

import json
import subprocess
import sys
import tempfile
from pathlib import Path


BINARY = Path(sys.argv[1]).resolve()
ROOT = Path(__file__).resolve().parents[1]


with tempfile.TemporaryDirectory() as directory:
    for variant in ("default", "sprint"):
        output = Path(directory) / variant
        subprocess.run([str(BINARY), str(output), "10", "1", variant], cwd=ROOT, check=True)
        manifest = json.loads((output / "manifest.json").read_text())
        train = [json.loads(line) for line in (output / "train.jsonl").read_text().splitlines()]
        validation = [json.loads(line) for line in (output / "validation.jsonl").read_text().splitlines()]
        assert manifest["variant"] == variant and manifest["teacher"] == "scripted-formation"
        assert len(manifest["runs"]) == 10
        assert len(train) == manifest["train_examples"]
        assert len(validation) == manifest["validation_examples"]
        assert {run["seed"] for run in manifest["runs"]} == set(range(1, 11))
        assert all(int(row["seed"].split("-")[-1]) % 5 != 0 for row in train)
        assert all(int(row["seed"].split("-")[-1]) % 5 == 0 for row in validation)
        for row in train + validation:
            view = json.loads(row["prompt"][1]["content"])
            answer = json.loads(row["completion"][0]["content"])
            assert "seed" not in view and len(view["your_robots"]) == 3
            assert len(answer["robots"]) == 3
            assert set(row) >= {"game", "action_schema_revision", "episode_id", "decision_id"}
        print(variant, len(train), len(validation))
