"""A new viewer receives the actual frozen board during a native HTTP wait."""

import http.server
from collections import Counter
import json
import os
import socket
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

from websockets.sync.client import connect

game, player, destination = sys.argv[1:4]
interrupt = sys.argv[4] if len(sys.argv) == 5 else ""
is_signal = interrupt in {"TERM", "INT", "disconnect"}
artifact_requests = []
second_started = threading.Event()
request_counts = Counter()
output = Path(destination)
output.mkdir(mode=0o700)
entered = threading.Event()
release = threading.Event()


class Provider(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        assert "PRIVATE_VIEWER_WAIT_OPERATOR" in body["messages"][0]["content"]
        assert body["max_tokens"] == 64
        seat = self.headers["X-Coworld-Player-Slot"]
        request_counts[seat] += 1
        if interrupt == "repair" and request_counts[seat] == 1:
            self.send_response(200)
            self.send_header("Content-Length", "4096")
            self.end_headers()
            self.wfile.write(b"\xc3")
            self.wfile.flush()
            entered.set()
            assert second_started.wait(12)
            return
        if interrupt == "repair":
            second_started.set()
        if is_signal:
            self.send_response(200)
            self.send_header("Content-Length", "4096")
            self.end_headers()
            self.wfile.write(b"\xc3")
            self.wfile.flush()
            entered.set()
            assert release.wait(8)
            return
        entered.set()
        assert release.wait(8)
        view = json.loads(body["messages"][0]["content"].rsplit("\n\n", 1)[1])
        directive = {
            "note": "local transport fixture",
            "robots": [
                {
                    "id": robot["id"],
                    "role": "back",
                    "intent": "hold",
                    "target": robot["pos"],
                    "pass_to": None,
                    "kick": "never",
                    "say": "",
                }
                for robot in view["your_robots"]
            ],
        }
        payload = {
            "model": "fixture/served",
            "stop_reason": "end_turn",
            "content": [{"type": "text", "text": json.dumps(directive)}],
        }
        if interrupt == "large":
            payload["sampling_evidence"] = {
                "prompt_token_ids": list(range(32768)),
                "completion_token_ids": [11, 12],
                "behavior_log_probs": [-0.1, -0.2],
                "stop_reason": "eos",
            }
        response = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def do_PUT(self):
        artifact_requests.append(self.path)
        body = self.rfile.read(int(self.headers["content-length"]))
        private = output / "private.jsonl"
        with private.open("xb") as archive:
            archive.write(body)
        private.chmod(0o600)
        self.send_response(503)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_args):
        pass


provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
provider.daemon_threads = False
provider_owner = threading.Thread(target=provider.serve_forever)
provider_owner.start()
with socket.socket() as reserved:
    reserved.bind(("127.0.0.1", 0))
    port = reserved.getsockname()[1]
config = output / "config.json"
config.write_text(
    json.dumps(
        {
            "num_agents": 2,
            "seed": 7,
            "tokens": ["t0", "t1"],
            "players": ["azure", "crimson"],
            "maxOutputTokens": 64,
            "maxTicks": 4800 if interrupt == "full_match" else 120,
            "turnTicks": 120,
            "startWaitTicks": 4,
            "lobbyJoinTimeoutTicks": 240,
            "minPlayers": 2,
            "fastMode": True,
            "wallClockBudgetSeconds": 720 if interrupt == "full_match" else 30,
            "gameOverTicks": 0,
        }
    )
)
env = {
    **os.environ,
    "COGAME_HOST": "127.0.0.1",
    "COGAME_PORT": str(port),
    "COGAME_CONFIG_URI": config.as_uri(),
    "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{provider.server_port}",
    "COWORLD_LLM_MODEL": "fixture/requested",
    "PLAYER_PROMPT": "PRIVATE_VIEWER_WAIT_OPERATOR",
    "COGAME_SAVE_TRAJECTORY_URI": (
        f"http://127.0.0.1:{provider.server_port}/private"
        if interrupt == "upload_failure"
        else (output / "private.jsonl").as_uri()
    ),
    "COGAME_SAVE_REPLAY_URI": (output / "replay.bitreplay").as_uri(),
    "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
    "COWORLD_EPISODE_ID": "cogball-local-viewer-wait",
    "COWORLD_GAME_VERSION": "fixture-native-runtime",
    "COWORLD_SOURCE_REVISION": "a" * 40,
}
processes = []
logs = []
try:
    game_log = (output / "game.log").open("w")
    logs.append(game_log)
    processes.append(
        subprocess.Popen([game], env=env, stdout=game_log, stderr=game_log)
    )
    for _ in range(100):
        with socket.socket() as probe:
            if probe.connect_ex(("127.0.0.1", port)) == 0:
                break
        time.sleep(0.05)
    else:
        raise AssertionError("owned game listener did not open")
    for seat in range(2):
        log = (output / f"player-{seat}.log").open("w")
        logs.append(log)
        player_env = {
            **env,
            "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
        }
        processes.append(
            subprocess.Popen([player], env=player_env, stdout=log, stderr=log)
        )
    assert entered.wait(10), "no actual native HTTP request entered"
    started = time.monotonic()
    with connect(f"ws://127.0.0.1:{port}/global", open_timeout=1) as viewer:
        packet = viewer.recv(timeout=1)
        elapsed = time.monotonic() - started
        assert isinstance(packet, bytes) and len(packet) > 1000
        assert b"PRIVATE_VIEWER_WAIT_OPERATOR" not in packet
    assert elapsed < 1
    if interrupt == "disconnect":
        processes[1].kill()
        processes[1].wait(timeout=2)
    if is_signal:
        processes[0].send_signal(
            signal.SIGTERM if interrupt in {"TERM", "disconnect"} else signal.SIGINT
        )
    else:
        release.set()
    for index, process in enumerate(processes):
        assert process.wait(timeout=240 if interrupt == "full_match" else 10) == (
            -signal.SIGKILL
            if interrupt == "disconnect" and index == 1
            else 1
            if interrupt == "upload_failure" and index == 0
            else 0
        )
    events = [
        json.loads(line) for line in (output / "private.jsonl").read_text().splitlines()
    ]
    terminal = events[-1]
    if interrupt == "upload_failure":
        assert artifact_requests == ["/private"]
        assert terminal["status"] == "completed"
        assert (
            not (output / "results.json").exists()
            and not (output / "replay.bitreplay").exists()
        )
        print(
            json.dumps(
                {
                    "case": "upload_failure",
                    "private_requests": 1,
                    "public_writes": 0,
                    "scope": "actual private HTTP503 propagates, no second seal",
                }
            )
        )
        sys.exit(0)
    if is_signal:
        assert terminal["status"] == "truncated"
        if interrupt == "disconnect":
            assert any(
                seat["status"] == "unresolved"
                for seat in terminal["outcome"]["player_cleanup"]
            )
            assert len(terminal["outcome"]["player_cleanup"]) == 2
        else:
            assert all(
                seat["status"] == "acknowledged"
                for seat in terminal["outcome"]["player_cleanup"]
            )
        assert not (output / "results.json").exists()
        assert not (output / "replay.bitreplay").exists()
        attempts = [
            attempt
            for event in events
            if event["event_type"] == "decision"
            for attempt in event["attempts"]
        ]
        assert any(
            attempt["response_body_b64"] == "ww=="
            and attempt["response_complete"] is False
            and attempt["response_reader_joined"] is True
            for attempt in attempts
        )
        assert all(
            event["selected_attempt_id"] is None
            and event["observation"]["execution"] is None
            for event in events
            if event["event_type"] == "decision"
        )
        release.set()
        print(
            json.dumps(
                {
                    "signal": interrupt,
                    "status": "truncated",
                    "joined_attempts": len(attempts),
                    "frame_bytes": len(packet),
                    "scope": "actual partial HTTP/game stop, zero serving authority",
                }
            )
        )
        sys.exit(0)
    assert terminal["event_type"] == "episode" and terminal["status"] == "completed"
    assert all(
        seat["status"] == "acknowledged"
        for seat in terminal["outcome"]["player_cleanup"]
    )
    decisions = [event for event in events if event["event_type"] == "decision"]
    assert len(decisions) >= 2
    if interrupt != "full_match":
        assert len(decisions) == 2
    for decision in decisions:
        assert decision["action_status"] == "accepted"
        selected = next(
            attempt
            for attempt in decision["attempts"]
            if attempt["attempt_id"] == decision["selected_attempt_id"]
        )
        assert selected["origin"] == "model" and selected["accepted"]
        assert selected["response_complete"] and selected["response_reader_joined"]
        assert selected["parsed_action"] == decision["executed_action"]
        if interrupt == "repair":
            assert len(decision["attempts"]) == 2
            first = decision["attempts"][0]
            assert not first["accepted"] and first["response_body_b64"] == "ww=="
            assert (
                first["response_complete"] is False
                and first["response_reader_joined"] is True
            )
        if interrupt == "large":
            assert selected["prompt_token_ids"] == list(range(32768))
            assert selected["sampled_token_ids"] == [11, 12]
            assert selected["behavior_logprobs"] == [-0.1, -0.2]
    assert (output / "results.json").is_file() and (
        output / "replay.bitreplay"
    ).is_file()
    print(
        json.dumps(
            {
                "viewer_first_frame_seconds": elapsed,
                "frame_bytes": len(packet),
                "decisions": len(decisions),
                "private_status": terminal["status"],
                "scope": "actual game frozen board during local HTTP fixture; zero model authority",
            }
        )
    )
finally:
    if interrupt == "disconnect":
        processes[1].kill()
        processes[1].wait(timeout=2)
    if interrupt:
        processes[0].send_signal(
            signal.SIGTERM if interrupt in {"TERM", "disconnect"} else signal.SIGINT
        )
    else:
        release.set()
    for process in processes:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
    for log in logs:
        log.close()
    provider.shutdown()
    provider_owner.join(timeout=2)
    assert not provider_owner.is_alive()
    provider.server_close()
