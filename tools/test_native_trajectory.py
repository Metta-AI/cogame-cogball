"""Actual coach players, private attempts and physical masks; local HTTP fixtures only."""

import base64
import contextlib
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME, PLAYER = (str(Path(arg).resolve()) for arg in sys.argv[1:3])
for flow in (
    "accepted",
    "invalid",
    "sampled",
    "greedy-null",
    "greedy-tokens",
    "provider-error",
    "malformed-200",
    "timeout",
):
    calls = {}
    timeout_requests = []

    class Provider(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["content-length"])))
            slot = int(self.headers["X-Coworld-Player-Slot"])
            assert self.path == "/v1/messages" and slot in range(2)
            assert request["temperature"] == (1 if flow == "sampled" else 0)
            view = json.loads(request["messages"][0]["content"].split("\n\n", 1)[1])
            action = {
                "note": "public coaching note",
                "robots": [
                    {
                        "id": robot["id"],
                        "role": "wing",
                        "intent": "hold",
                        "target": robot["pos"],
                        "pass_to": None,
                        "kick": "never",
                        "say": "public robot speech",
                    }
                    for robot in view["your_robots"]
                ],
            }
            text = (
                "private-invalid-response"
                if flow == "invalid" and slot == 0
                else json.dumps(action)
            )
            if flow == "timeout" and slot == 0:
                timeout_requests.append(request)
                time.sleep(8)
                return
            call_id = str(uuid.uuid4())
            body = {
                "id": "msg_" + call_id,
                "model": "fixture/served",
                "stop_reason": "end_turn",
                "content": [{"type": "text", "text": text}],
                "usage": {"input_tokens": 12, "output_tokens": 4},
            }
            if flow == "greedy-null":
                body["sampling_evidence"] = None
            if flow in {"sampled", "greedy-tokens"}:
                body["sampling_evidence"] = {
                    "policy_revision": "a" * 64,
                    "tokenizer_revision": "b" * 64,
                    "chat_template": "fixture-template",
                    "sampling": "full_softmax_temperature_one"
                    if flow == "sampled"
                    else "greedy",
                    "enable_thinking": False,
                    "max_new_tokens": request["max_tokens"],
                    "max_sequence_length": 4096,
                    "sampling_seed": 7,
                    "eos_token_ids": [4],
                    "prompt_token_ids": [1, 2],
                    "completion_token_ids": [3, 4],
                    "behavior_log_probs": [-0.5, -0.3] if flow == "sampled" else None,
                    "stop_reason": "eos",
                    "response": text,
                }
            if flow == "provider-error" and slot == 0:
                body = {"error": {"message": "private-provider-error"}}
            if flow == "malformed-200" and slot == 0:
                body = "private-malformed-provider"
            calls[call_id] = (request, body)
            encoded = (
                body.encode() if isinstance(body, str) else json.dumps(body).encode()
            )
            self.send_response(429 if flow == "provider-error" and slot == 0 else 200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(encoded)))
            self.send_header("X-Softmax-Llm-Call-Id", call_id)
            if flow in {"sampled", "greedy-tokens"}:
                self.send_header("X-Coworld-Checkpoint-Sha256", "a" * 64)
                self.send_header("X-Coworld-Tokenizer-Sha256", "b" * 64)
                self.send_header("X-Coworld-Chat-Template-Sha256", "c" * 64)
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, *_args):
            pass

    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    provider.daemon_threads = False
    provider_owner = threading.Thread(target=provider.serve_forever, daemon=True)
    provider_owner.start()
    if len(sys.argv) == 4:
        target = Path(sys.argv[3]) / flow
        target.mkdir(parents=True, mode=0o700, exist_ok=False)
        output_context = contextlib.nullcontext(target)
    else:
        output_context = tempfile.TemporaryDirectory()
    with output_context as directory:
        output = Path(directory)
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        config = {
            "num_agents": 2,
            "seed": 7,
            "tokens": ["t0", "t1"],
            "players": ["fixture-azure", "fixture-crimson"],
            "maxTicks": 240,
            "turnTicks": 120,
            "startWaitTicks": 4,
            "lobbyJoinTimeoutTicks": 240,
            "minPlayers": 2,
            "fastMode": True,
            "wallClockBudgetSeconds": 60,
            "gameOverTicks": 0,
        }
        (output / "config.json").write_text(json.dumps(config))
        env = {
            **os.environ,
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(port),
            "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
            "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
            "COGAME_SAVE_REPLAY_URI": (output / "replay.bitreplay").as_uri(),
            "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
            "COWORLD_EPISODE_ID": str(uuid.uuid4()),
            "COWORLD_GAME_VERSION": "1",
            "COWORLD_SOURCE_REVISION": subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
            ).strip(),
            "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{provider.server_port}",
            "COWORLD_LLM_MODEL": "fixture/requested",
            "COWORLD_LLM_TEMPERATURE": "1" if flow == "sampled" else "0",
            "PLAYER_PROMPT": "private-guidance-fixture",
            "PLAYER_SCRIPTED": "",
        }
        processes, logs = [], []
        try:
            log = (output / "game.log").open("w")
            logs.append(log)
            processes.append(
                subprocess.Popen([GAME], cwd=ROOT, env=env, stdout=log, stderr=log)
            )
            for _ in range(100):
                if processes[0].poll() is not None:
                    raise AssertionError((output / "game.log").read_text())
                with socket.socket() as check:
                    if check.connect_ex(("127.0.0.1", port)) == 0:
                        break
                time.sleep(0.05)
            else:
                raise AssertionError("game socket never opened")
            for slot in range(2):
                log = (output / f"player{slot}.log").open("w")
                logs.append(log)
                player_env = {
                    **env,
                    "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={slot}&token=t{slot}",
                }
                processes.append(
                    subprocess.Popen(
                        [PLAYER], cwd=ROOT, env=player_env, stdout=log, stderr=log
                    )
                )
            for process in processes:
                assert process.wait(timeout=90) == 0
            for log in logs:
                log.flush()
            events = [
                json.loads(line)
                for line in (output / "trajectory.jsonl").read_text().splitlines()
            ]
            decisions, episode = events[:-1], events[-1]
            assert (
                episode["status"] == "completed"
                and episode["outcome"]["reason"] == "complete"
            )
            assert len(decisions) == 4
            assert (output / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
            seen = set()
            for decision in decisions:
                assert decision["execution"] is None
                slot = int(decision["seat"])
                physical = decision["observation"]["execution"]
                assert (
                    physical["control_encoding"] == "sprite-three-u8"
                    and physical["tick_hz"] == 24
                )
                duration = physical["end_tick"] - physical["start_tick"]
                assert (
                    duration > 0
                    and len(base64.b64decode(physical["seat_input_masks_b64"]))
                    == 3 * duration
                )
                assert len(physical["post_tick_hashes"]) == duration
                for attempt in decision["attempts"]:
                    assert attempt["inference_mode"] == "text_action"
                    if flow == "timeout" and slot == 0:
                        assert attempt["origin"] == "model" and not attempt["accepted"]
                        assert attempt["request"] in timeout_requests
                        assert (
                            attempt["prompt"][1]["content"]
                            == attempt["request"]["messages"][0]["content"]
                        )
                        assert attempt["platform_call_id"] is None
                        assert (
                            attempt["response"] is None
                            and attempt["raw_response"] is None
                        )
                        assert attempt["latency_ms"] is not None
                        assert attempt["response_complete"] is None
                        assert attempt["http_status"] is None
                        assert attempt["response_headers_b64"] is None
                        assert attempt["response_body_b64"] is None
                        assert attempt["response_reader_joined"] is True
                        assert attempt["rejection_reason"].startswith(
                            "incomplete_native_attempt: timeout"
                        )
                    if attempt["platform_call_id"] is None:
                        continue
                    call_id = attempt["platform_call_id"]
                    assert call_id not in seen
                    seen.add(call_id)
                    request, body = calls[call_id]
                    assert attempt["request"] == request
                    assert (
                        attempt["raw_response"]
                        if isinstance(body, str)
                        else json.loads(attempt["raw_response"])
                    ) == body
                    if flow in {"provider-error", "malformed-200"} and slot == 0:
                        assert (
                            attempt["response"] is None
                            and attempt["latency_ms"] is not None
                        )
                        assert not attempt["rejection_reason"].startswith(
                            "incomplete_native_attempt:"
                        )
                    assert attempt["prompt"][0]["content"] == request["system"]
                    assert (
                        attempt["prompt"][1]["content"]
                        == request["messages"][0]["content"]
                    )
                    if "model" in body:
                        assert attempt["model"] == "fixture/served"
                        assert (
                            attempt["input_tokens"] == 12
                            and attempt["output_tokens"] == 4
                        )
                    if flow == "greedy-tokens":
                        assert (
                            attempt["sampled_token_ids"] == [3, 4]
                            and attempt["behavior_logprobs"] is None
                        )
                if decision["action_status"] == "accepted":
                    selected = next(
                        a
                        for a in decision["attempts"]
                        if a["attempt_id"] == decision["selected_attempt_id"]
                    )
                    assert (
                        selected["accepted"]
                        and selected["parsed_action"] == decision["executed_action"]
                    )
                else:
                    assert decision["selected_attempt_id"] is None
            assert seen == set(calls)
            public = (output / "replay.bitreplay").read_bytes().decode(
                "latin1"
            ) + "".join(
                (output / p).read_text()
                for p in ["game.log", *(f"player{i}.log" for i in range(2))]
            )
            for secret in (
                "private-guidance-fixture",
                "private-invalid-response",
                "private-provider-error",
                "private-malformed-provider",
            ):
                assert secret not in public
            if flow in {"invalid", "provider-error", "malformed-200", "timeout"}:
                assert any(
                    d["action_status"] == "fallback" and len(d["attempts"]) == 2
                    for d in decisions
                )
            archive = output / "fixture_calls.json"
            archive.write_text(
                json.dumps(
                    {
                        "cohort": "local HTTP fixture, not real platform archive",
                        "synthetic_model_identities": True,
                        "calls": calls,
                    }
                )
            )
            archive.chmod(0o600)
            print(
                flow,
                len(decisions),
                "macros",
                len(calls),
                "native fixture joins",
                flush=True,
            )
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
            for log in logs:
                log.close()
            provider.shutdown()
            provider.server_close()
            provider_owner.join(timeout=2)
            assert not provider_owner.is_alive()
