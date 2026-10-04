"""Reject observed starts and preserve joined facts through actual socket ingress."""
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

GAME, PLAYER, OUTPUT = (Path(value).resolve() for value in sys.argv[1:4])
ROOT = Path(__file__).resolve().parents[1]
MODE = sys.argv[4] if len(sys.argv) == 5 else "first"
assert MODE in ("first", "joined")
OUTPUT.mkdir(mode=0o700, parents=True, exist_ok=False)
with socket.socket() as reserve:
    reserve.bind(("127.0.0.1", 0))
    port = reserve.getsockname()[1]
config = {"num_agents": 2, "tokens": ["t0", "t1"], "seed": 7,
          "maxTicks": 240, "turnTicks": 120, "startWaitTicks": 4,
          "lobbyJoinTimeoutTicks": 240, "minPlayers": 2, "fastMode": True,
          "wallClockBudgetSeconds": 60, "gameOverTicks": 0}
(OUTPUT / "config.json").write_text(json.dumps(config))
env = os.environ | {
    "COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port),
    "COGAME_CONFIG_URI": (OUTPUT / "config.json").as_uri(),
    "COGAME_RESULTS_URI": (OUTPUT / "results.json").as_uri(),
    "COGAME_SAVE_REPLAY_URI": (OUTPUT / "replay.json").as_uri(),
    "COGAME_SAVE_TRAJECTORY_URI": (OUTPUT / "trajectory.jsonl").as_uri(),
    "COWORLD_EPISODE_ID": "socket-chronology-" + MODE,
    "ASSERTED_CHRONOLOGY": MODE,
    "COWORLD_GAME_VERSION": "diagnostic-first-finished",
    "COWORLD_SOURCE_REVISION": os.environ["COWORLD_TEST_SOURCE_REVISION"],
}
processes, logs = [], []
try:
    log = (OUTPUT / "game.log").open("w")
    logs.append(log)
    processes.append(subprocess.Popen([str(GAME)], cwd=ROOT, env=env, stdout=log, stderr=log))
    deadline = time.monotonic() + 5
    while True:
        with socket.socket() as probe:
            ready = probe.connect_ex(("127.0.0.1", port)) == 0
        if ready: break
        assert processes[0].poll() is None and time.monotonic() < deadline
        time.sleep(.02)
    for slot in range(2):
        log = (OUTPUT / f"player{slot}.log").open("w")
        logs.append(log)
        player_env = env | {"COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={slot}&token=t{slot}"}
        processes.append(subprocess.Popen([str(PLAYER)], cwd=ROOT, env=player_env, stdout=log, stderr=log))
    for process in processes: assert process.wait(timeout=60) == 0
    events = [json.loads(line) for line in (OUTPUT / "trajectory.jsonl").read_text().splitlines()]
    decisions, episode = events[:-1], events[-1]
    assert episode["status"] == "completed" and len(decisions) == 4
    if MODE == "first":
        assert all(decision["selected_attempt_id"] is None for decision in decisions)
        assert all(not attempt["accepted"] for decision in decisions for attempt in decision["attempts"])
    else:
        attempts = [attempt for decision in decisions for attempt in decision["attempts"]
                    if attempt["origin"] == "model"]
        assert len(attempts) == 4
        assert all(attempt["input_tokens"] is None and attempt["latency_ms"] is None
                   and attempt["response_reader_joined"] is True for attempt in attempts)
    print(MODE, "invalid chronology rejected across", len(decisions), "authoritative decisions")
finally:
    for process in processes:
        if process.poll() is None: process.terminate()
    for process in processes:
        if process.poll() is None: process.wait(timeout=10)
    for log in logs: log.close()
