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
        subprocess.run(
            [str(BINARY), str(output), "10", "1", variant], cwd=ROOT, check=True
        )
        manifest = json.loads((output / "manifest.json").read_text())
        events = [
            json.loads(line)
            for line in (output / "trajectories.jsonl").read_text().splitlines()
        ]
        assert (
            manifest["variant"] == variant
            and manifest["teacher"] == "scripted-formation"
        )
        assert len(manifest["runs"]) == 10
        episodes = [event for event in events if event["event_type"] == "episode"]
        decisions = [event for event in events if event["event_type"] == "decision"]
        assert len(episodes) == 10 and all(
            event["status"] == "completed" for event in episodes
        )
        assert {event["seed_family"] for event in episodes} == {
            f"cogball-{seed}" for seed in range(1, 11)
        }
        assert {event["source_revision"] for event in events} == {
            manifest["source_revision"]
        }
        assert (
            not (output / "train.jsonl").exists()
            and not (output / "validation.jsonl").exists()
        )
        assert (output / "trajectories.jsonl").stat().st_mode & 0o777 == 0o600
        assert output.stat().st_mode & 0o777 == 0o700
        first_by_seat = set()
        for row in decisions:
            selected = next(
                attempt
                for attempt in row["attempts"]
                if attempt["attempt_id"] == row["selected_attempt_id"]
            )
            view = json.loads(selected["prompt"][1]["content"].split("\n\n", 1)[1])
            answer = json.loads(selected["response"])
            assert "seed" not in view and len(view["your_robots"]) == 3
            assert (
                selected["origin"] == "teacher"
                and selected["inference_mode"] == "text_action"
            )
            assert selected["platform_call_id"] is None
            for field in (
                "model",
                "request",
                "raw_response",
                "decoder",
                "response_headers",
                "response_body_b64",
                "response_headers_b64",
                "response_complete",
                "response_reader_joined",
                "http_status",
            ):
                assert selected[field] is None
            key = row["episode_id"], row["seat"]
            if key not in first_by_seat:
                first_by_seat.add(key)
                assert 0 < view["clock"]["played_s"] < 0.05
                execution = row["observation"]["execution"]
                assert execution["end_tick"] - execution["start_tick"] == 119
            assert answer == selected["parsed_action"] == row["executed_action"]
            assert len(answer["robots"]) == 3
        print(variant, len(episodes), len(decisions), "canonical teacher decisions")
