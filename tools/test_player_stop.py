"""Stop and signals join the real HTTP owner before private evidence delivery."""

import base64
import http.server
import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

from websockets.sync.server import serve

binary, destination = sys.argv[1:]
output = Path(destination)
output.mkdir(mode=0o700)
for mode in ("stop", "phase_stop", "term", "int", "deadline"):
    entered = threading.Event()
    release = threading.Event()
    acknowledged = threading.Event()
    results = []
    requests = []

    class Provider(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["content-length"])))
            requests.append(request)
            assert request["system"] == "PRIVATE_SYSTEM_STOP_SENTINEL"
            assert request["messages"] == [
                {"role": "user", "content": "PRIVATE_USER_STOP_SENTINEL"}
            ]
            assert self.headers["X-Coworld-Player-Slot"] == "0"
            self.send_response(200)
            self.send_header("Content-Length", "1000")
            self.end_headers()
            self.wfile.write(b"\xc3")
            self.wfile.flush()
            entered.set()
            assert release.wait(5)

        def log_message(self, *_args):
            pass

    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    provider.daemon_threads = False
    http_owner = threading.Thread(target=provider.serve_forever)
    http_owner.start()

    def handle(
        connection,
        mode=mode,
        entered=entered,
        acknowledged=acknowledged,
        results=results,
    ):
        assert isinstance(connection.recv(timeout=1), bytes)
        connection.send(
            json.dumps(
                {
                    "type": "decision",
                    "decision_id": "issued-stop-operation",
                    "seat": 0,
                    "observation": {},
                    "messages": [
                        {"role": "system", "content": "PRIVATE_SYSTEM_STOP_SENTINEL"},
                        {"role": "user", "content": "PRIVATE_USER_STOP_SENTINEL"},
                    ],
                    "transport": {
                        "budget_ms": 6000,
                        "cleanup_budget_ms": 3000,
                        "max_output_tokens": 64,
                    },
                }
            )
        )
        start = json.loads(connection.recv(timeout=1))
        assert start["type"] == "attempt_started"
        assert start["training_attempt"]["response_body_b64"] is None
        assert entered.wait(2)
        time.sleep(0.1)
        started = time.monotonic()
        nonce = "actual-issued-stop-nonce" if mode in {"stop", "phase_stop"} else None
        expected_id = start["decision_id"]
        if mode == "phase_stop":
            expected_id = "issued-repair-operation"
            connection.send(
                json.dumps(
                    {
                        "type": "decision",
                        "decision_id": expected_id,
                        "seat": 0,
                        "observation": {},
                        "messages": [
                            {
                                "role": "system",
                                "content": "PRIVATE_SYSTEM_STOP_SENTINEL",
                            },
                            {"role": "user", "content": "PRIVATE_USER_STOP_SENTINEL"},
                        ],
                        "transport": {
                            "budget_ms": 2500,
                            "cleanup_budget_ms": 3000,
                            "max_output_tokens": 64,
                        },
                    }
                )
            )
            phase = json.loads(connection.recv(timeout=3))
            while phase["type"] == "action":
                assert phase["decision_id"] == start["decision_id"]
                phase = json.loads(connection.recv(timeout=3))
            assert phase["type"] == "stopped" and phase["stop_id"] is None
            assert phase["decision_id"] == start["decision_id"]
            assert phase["attempts"][0]["response_reader_joined"] is True
            # Stop arrives while the previous evidence receipt is withheld.
        if mode in {"stop", "phase_stop"}:
            connection.send(
                json.dumps(
                    {
                        "type": "stop",
                        "decision_id": expected_id,
                        "stop_id": nonce,
                        "cleanup_budget_ms": 3000,
                        "max_output_tokens": 64,
                    }
                )
            )
        elif mode != "deadline":
            process.send_signal(signal.SIGTERM if mode == "term" else signal.SIGINT)
        stopped = json.loads(connection.recv(timeout=3))
        assert stopped["type"] == "stopped"
        assert stopped["worker_status"] in (
            {"joined", "no_active_call"}
            if mode == "deadline"
            else {"no_active_call"}
            if mode == "phase_stop"
            else {"joined"}
        )
        assert stopped["decision_id"] == expected_id and stopped["stop_id"] == nonce
        assert len(stopped["attempts"]) == 1
        attempt = stopped["attempts"][0]
        assert base64.b64decode(attempt["response_body_b64"], validate=True) == b"\xc3"
        assert (
            attempt["response_complete"] is False
            and attempt["response_reader_joined"] is True
        )
        assert attempt["http_status"] == 200 and attempt["raw_response"] is None
        assert attempt["response"] is None and attempt["platform_call_id"] is None
        assert attempt["request"] == start["training_attempt"]["request"]
        connection.send(
            json.dumps(
                {
                    "type": "evidence_received",
                    "decision_id": stopped["decision_id"],
                    "stop_id": nonce,
                }
            )
        )
        results.append(
            {
                "mode": mode,
                "joined_seconds": time.monotonic() - started,
                "scope": "actual partial invalid-UTF8 HTTP owner; synthetic socket authority only",
            }
        )
        assert len(requests) == 1, (
            "phase stop started an unacknowledged next HTTP request"
        )
        acknowledged.set()

    server = serve(handle, "127.0.0.1", 0)
    ws_owner = threading.Thread(target=server.serve_forever)
    ws_owner.start()
    env = {
        **os.environ,
        "PLAYER_PROMPT": "PRIVATE_OPERATOR_STOP_SENTINEL",
        "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{server.socket.getsockname()[1]}/player",
        "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{provider.server_port}",
        "COWORLD_LLM_MODEL": "fixture/requested",
        "COWORLD_TIMEOUT_SECONDS": "0.4" if mode == "deadline" else "10",
    }
    log_path = output / (mode + ".log")
    with log_path.open("w") as log:
        process = subprocess.Popen([binary], env=env, stdout=log, stderr=log)
        try:
            assert acknowledged.wait(5)
            assert process.wait(timeout=1) == 0
            assert len(results) == 1
            assert "PRIVATE_" not in log_path.read_text()
            print(json.dumps(results[0]), flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            release.set()
            server.shutdown()
            ws_owner.join(timeout=2)
            assert not ws_owner.is_alive()
            provider.shutdown()
            http_owner.join(timeout=2)
            assert not http_owner.is_alive()
            provider.server_close()
            log_path.chmod(0o600)
