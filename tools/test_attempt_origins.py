"""Untrusted provenance and model-response binding through real player sockets."""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
GAME, PLAYER, REPLAY_CHECK = (str(Path(arg).resolve()) for arg in sys.argv[1:4])
for attack in ("teacher", "human", "mismatch"):
    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory)
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        config = {"num_agents": 2, "seed": 7, "tokens": ["t0", "t1"],
                  "players": ["fixture-azure", "fixture-crimson"], "maxTicks": 240,
                  "turnTicks": 120, "startWaitTicks": 4, "minPlayers": 2,
                  "fastMode": True, "lobbyJoinTimeoutTicks": 240, "gameOverTicks": 0,
                  "wallClockBudgetSeconds": 60}
        (output / "config.json").write_text(json.dumps(config))
        env = {**os.environ, "COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port),
               "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
               "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
               "COGAME_SAVE_REPLAY_URI": (output / "replay.bitreplay").as_uri(),
               "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
               "COWORLD_EPISODE_ID": str(uuid.uuid4()), "COWORLD_GAME_VERSION": "1",
               "COWORLD_SOURCE_REVISION": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
               "COWORLD_ATTACK": attack}
        processes, logs = [], []
        try:
            log = (output / "game.log").open("w"); logs.append(log)
            game = subprocess.Popen([GAME], cwd=ROOT, env=env, stdout=log, stderr=log); processes.append(game)
            for _ in range(100):
                assert game.poll() is None
                with socket.socket() as check:
                    if check.connect_ex(("127.0.0.1", port)) == 0: break
                time.sleep(.05)
            else: raise AssertionError("game never listened")
            for seat in range(2):
                log = (output / f"player{seat}.log").open("w"); logs.append(log)
                processes.append(subprocess.Popen([PLAYER], cwd=ROOT, env={**env,
                    "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}"},
                    stdout=log, stderr=log))
            assert game.wait(timeout=90) == 0
            decisions = [json.loads(line) for line in (output / "trajectory.jsonl").read_text().splitlines()
                         if json.loads(line)["event_type"] == "decision"]
            assert len(decisions) == 4
            for decision in decisions:
                if attack == "mismatch":
                    assert decision["action_status"] == "fallback" and decision["selected_attempt_id"] is None
                    assert len(decision["attempts"]) == 2
                    assert all(not attempt["accepted"] and attempt["parsed_action"] != decision["executed_action"]
                               for attempt in decision["attempts"])
                else:
                    assert decision["action_status"] == "accepted"
                    assert all(attempt["origin"] == "unknown" for attempt in decision["attempts"])
            subprocess.run([REPLAY_CHECK, str(output / "replay.bitreplay"), str(output / "trajectory.jsonl")], check=True)
            print(attack, "four actual socket macros passed", flush=True)
        finally:
            for process in processes:
                if process.poll() is None: process.terminate(); process.wait(timeout=5)
            for log in logs: log.close()
