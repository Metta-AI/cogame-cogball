"""Actual invalid configuration and occupied listener retain one private failure."""

import json
import os
import socket
import subprocess
import sys
from pathlib import Path

game, destination = sys.argv[1:]
root = Path(destination)
root.mkdir(mode=0o700)
for case in ("invalid_config", "zero_native_cap", "bind_failure"):
    output = root / case
    output.mkdir(mode=0o700)
    config = output / "config.json"
    config.write_text(
        json.dumps(
            {
                "seed": 7,
                "num_agents": 2,
                "maxTicks": 0 if case == "invalid_config" else 120,
                "maxOutputTokens": 0 if case == "zero_native_cap" else 900,
            }
        )
    )
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        env = {
            **os.environ,
            "COGAME_CONFIG_URI": config.as_uri(),
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(listener.getsockname()[1]),
            "COGAME_SAVE_TRAJECTORY_URI": (output / "private.jsonl").as_uri(),
            "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
            "COWORLD_EPISODE_ID": "fixture-initialization-" + case,
            "COWORLD_GAME_VERSION": "fixture-runtime",
            "COWORLD_SOURCE_REVISION": "a" * 40,
        }
        with (output / "game.log").open("w") as log:
            process = subprocess.run([game], env=env, stdout=log, stderr=log, timeout=5)
        assert process.returncode != 0
    events = [
        json.loads(line) for line in (output / "private.jsonl").read_text().splitlines()
    ]
    assert len(events) == 1 and events[0]["status"] == "failed"
    assert events[0]["outcome"]["reason"] == "runtime_initialization"
    assert not (output / "results.json").exists()
    assert (output / "private.jsonl").stat().st_mode & 0o777 == 0o600
    print(
        json.dumps(
            {
                "case": case,
                "status": "failed",
                "events": 1,
                "scope": "source initialization diagnostic; no model authority",
            }
        )
    )
