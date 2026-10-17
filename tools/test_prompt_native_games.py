"""Full native-player games exercise actual failed requests and consumed fallbacks."""

import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import uuid

VARIANTS = ["canonical", "plain", "numbered", "questions", "reordered"]


def metadata(messages, choice, seed):
    return {
        "bank": "cogball-rules-v1",
        "variant": VARIANTS[seed] if choice == "mixed" else choice,
        "selection": choice,
        "seed": seed,
        "system_sha256": hashlib.sha256(messages[0]["content"].encode()).hexdigest(),
        "user_sha256": hashlib.sha256(messages[1]["content"].encode()).hexdigest(),
    }


GAME, PLAYER, OUTPUT = (Path(value).resolve() for value in sys.argv[1:4])
SOURCE = sys.argv[4]
REPLAY_CHECK = str(Path(sys.argv[5]).resolve())
ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / "coworld_manifest_template.json").read_text())

for variant in manifest["variants"]:
    baseline = None
    for choice, prompt_seed in [
        (v, 0) for v in VARIANTS + ["heldout-briefing", "heldout-reference"]
    ] + [("mixed", i) for i in range(5)]:
        output = OUTPUT / f"{variant['id']}-{choice}-{prompt_seed}"
        output.mkdir(mode=0o700, parents=True, exist_ok=False)
        config = variant["game_config"] | {
            "tokens": ["0", "1"],
            "seed": 17,
            "promptVariant": choice,
            "promptSeed": prompt_seed,
        }
        (output / "config.json").write_text(json.dumps(config))
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        with socket.socket() as closed_endpoint:
            closed_endpoint.bind(("127.0.0.1", 0))
            environment = dict(os.environ)
            for key in (
                "ANTHROPIC_API_KEY",
                "ANTHROPIC_API_KEY_URI",
                "AWS_BEARER_TOKEN_BEDROCK",
                "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
            ):
                environment.pop(key, None)
            environment.update(
                COGAME_HOST="127.0.0.1",
                COGAME_PORT=str(port),
                COGAME_CONFIG_URI=(output / "config.json").as_uri(),
                COGAME_RESULTS_URI=(output / "results.json").as_uri(),
                COGAME_SAVE_REPLAY_URI=(output / "replay.bitreplay").as_uri(),
                COGAME_SAVE_TRAJECTORY_URI=(output / "trajectory.jsonl").as_uri(),
                COWORLD_SOURCE_REVISION=SOURCE,
                COWORLD_EPISODE_ID=str(uuid.uuid4()),
                COWORLD_GAME_VERSION="source-prompt-validation",
                COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{closed_endpoint.getsockname()[1]}",
                COWORLD_LLM_MODEL="closed-endpoint-validation",
            )
            processes, logs = [], []
            try:
                log = (output / "game.log").open("w")
                logs.append(log)
                game = subprocess.Popen(
                    [str(GAME)], cwd=ROOT, env=environment, stdout=log, stderr=log
                )
                processes.append(game)
                ready_deadline = time.monotonic() + 30
                while True:
                    with socket.socket() as probe:
                        ready = probe.connect_ex(("127.0.0.1", port)) == 0
                    if ready:
                        break
                    assert game.poll() is None and time.monotonic() < ready_deadline
                    time.sleep(0.02)
                for seat in range(2):
                    player_env = environment | {
                        "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token={seat}",
                        "PLAYER_SCRIPTED": "",
                        "PLAYER_PROMPT": f"PRIVATE-OPERATOR-{seat}: maximize your score.",
                    }
                    log = (output / f"player-{seat}.log").open("w")
                    logs.append(log)
                    processes.append(
                        subprocess.Popen(
                            [str(PLAYER)],
                            cwd=ROOT,
                            env=player_env,
                            stdout=log,
                            stderr=log,
                        )
                    )
                deadline = time.monotonic() + config["wallClockBudgetSeconds"] + 60
                for process in processes:
                    assert (
                        process.wait(timeout=max(1, deadline - time.monotonic())) == 0
                    )
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)
                for log in logs:
                    log.close()
        events = [
            json.loads(line)
            for line in (output / "trajectory.jsonl").read_text().splitlines()
        ]
        assert events[-1]["status"] == "completed"
        assert (output / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
        episode = events[-1]
        assert {
            receipt["seat"] for receipt in episode["outcome"]["player_cleanup"]
        } == {0, 1}
        assert all(
            receipt["status"] == "acknowledged"
            for receipt in episode["outcome"]["player_cleanup"]
        )
        expected = 80 if variant["id"] == "default" else 40
        assert len(events) - 1 == expected
        transcript = []
        selected = VARIANTS[prompt_seed] if choice == "mixed" else choice
        for event in events[:-1]:
            seat = int(event["seat"])
            view = event["observation"]
            assert view.pop("prompt_selection") == {
                "bank": "cogball-rules-v1",
                "variant": selected,
                "selection": choice,
                "seed": prompt_seed,
            }
            prompt_attempts = view.pop("prompt_attempts")
            attempts = event["attempts"]
            assert len(attempts) == 2
            assert (
                event["action_status"] == "fallback"
                and event["selected_attempt_id"] is None
            )
            assert prompt_attempts == [
                {
                    "attempt_id": a["attempt_id"],
                    "prompt_template": metadata(a["prompt"], choice, prompt_seed),
                }
                for a in attempts
            ]
            physical = view.pop("execution")
            assert physical["control_encoding"] == "sprite-three-u8"
            assert physical["end_tick"] > physical["start_tick"]
            users = []
            for attempt in attempts:
                assert attempt["origin"] == "model" and not attempt["accepted"]
                assert (
                    attempt["raw_response"] is None
                    and attempt["platform_call_id"] is None
                )
                assert attempt["response_reader_joined"] is True
                messages = attempt["prompt"]
                assert [m["role"] for m in messages] == ["system", "user"]
                system, user = (m["content"] for m in messages)
                assert f"PRIVATE-OPERATOR-{seat}" in user
                assert f"PRIVATE-OPERATOR-{1 - seat}" not in user
                assert json.loads(user.split("\n\n", 1)[1]) == view
                assert attempt["request"]["system"] == system
                assert attempt["request"]["messages"] == [
                    {"role": "user", "content": user}
                ]
                users.append(user)
            transcript.append((view, physical, users, event["executed_action"]))
        replay = (output / "replay.bitreplay").read_bytes()
        assert b"PRIVATE-OPERATOR" not in replay and b"prompt_template" not in replay
        subprocess.run(
            [
                REPLAY_CHECK,
                str(output / "replay.bitreplay"),
                str(output / "trajectory.jsonl"),
            ],
            cwd=ROOT,
            check=True,
            timeout=60,
        )
        results = json.loads((output / "results.json").read_text())
        assert results["reason"] == "complete"
        result = transcript, results
        if baseline is None:
            baseline = result
        assert result == baseline
        print(
            variant["id"],
            choice,
            prompt_seed,
            len(transcript),
            "native decisions PASS",
            flush=True,
        )
