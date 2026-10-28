"""Complete native Cogball with real bundled players and artifact/ACK fault controls."""

import argparse
import hashlib
import http.server
import json
import os
import shutil
import socket
import subprocess
import threading
import time
import urllib.request
from pathlib import Path

from websockets.exceptions import ConnectionClosed
from websockets.sync.client import connect
from websockets.sync.server import serve

ROOT = Path(__file__).resolve().parents[2]


def available_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, required=True)
    parser.add_argument("--player", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--case", choices=("noack", "private503", "private-slow", "ack"), required=True
    )
    args = parser.parse_args()
    os.umask(0o077)
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    temporary = output / "native-tmp"
    temporary.mkdir(mode=0o700)
    (output / "frozen-harness.py").write_bytes(Path(__file__).read_bytes())
    clean = {
        key: os.environ[key]
        for key in ("PATH", "HOME", "TMPDIR", "LANG")
        if key in os.environ
    }
    clean["TMPDIR"] = str(temporary)
    config = json.loads((ROOT / "config.json").read_text())
    # Published default match, including its real lobby and game-over countdown.
    assert config["maxTicks"] == 4800 and config["turnTicks"] == 120
    assert config["gameOverTicks"] == 120 and config["fastMode"] is True
    config.update(seed=7, tokens=["local-finalization-0", "local-finalization-1"])
    (output / "config.json").write_text(json.dumps(config, indent=2) + "\n")
    events, relay_stats, processes, logs = [], [], [], []
    lock = threading.Lock()
    release_upload = threading.Event()
    started = time.monotonic()

    def event(kind, **fields):
        with lock:
            events.append(
                {"kind": kind, "elapsed_s": time.monotonic() - started, **fields}
            )

    class Artifact(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_PUT(self):
            assert self.path == "/trajectory"
            size = int(self.headers["Content-Length"])
            assert 0 < size <= 32 * 2**20
            body = self.rfile.read(size)
            (output / "attempted-private-upload.jsonl").write_bytes(body)
            event(
                "private_upload_received",
                bytes=len(body),
                sha256=hashlib.sha256(body).hexdigest(),
            )
            if args.case == "private-slow":
                event("private_response_held")
                assert release_upload.wait(timeout=235)
            try:
                self.send_response(503 if args.case == "private503" else 200)
                self.send_header("Content-Length", "0")
                self.end_headers()
                event("private_response_sent")
            except OSError as error:
                event("private_response_peer_closed", error=type(error).__name__)

    artifact = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Artifact)
    artifact.daemon_threads = True
    artifact_owner = threading.Thread(target=artifact.serve_forever, daemon=True)
    artifact_owner.start()
    game_port = available_port()
    trajectory = (
        (f"http://127.0.0.1:{artifact.server_port}/trajectory")
        if args.case in ("private503", "private-slow")
        else (output / "trajectory.jsonl").as_uri()
    )
    env = clean | {
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": str(game_port),
        "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
        "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
        "COGAME_SAVE_REPLAY_URI": (output / "public.bitreplay").as_uri(),
        "COGAME_SAVE_TRAJECTORY_URI": trajectory,
        "COGAME_EVENTS_URI": (output / "events.jsonl").as_uri(),
        "COWORLD_EPISODE_ID": "local-cogball-finalization-" + args.case,
        "COWORLD_GAME_VERSION": "local-native-fixture",
        "COWORLD_SOURCE_REVISION": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, env=clean, text=True
        ).strip(),
    }
    source_files = [
        ROOT / "src/cogball/server.nim",
        ROOT / "src/cogball/training_capture.nim",
    ]
    source_hashes = {
        str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in source_files
    }
    dirty_runtime = (
        subprocess.run(
            ["git", "diff", "--quiet", "--", "src"], cwd=ROOT, env=clean
        ).returncode
        != 0
    )
    if dirty_runtime:
        env["COWORLD_SOURCE_REVISION"] += (
            "+uncommitted-"
            + hashlib.sha256(
                json.dumps(source_hashes, sort_keys=True).encode()
            ).hexdigest()
        )
    (output / "source-bindings.json").write_text(
        json.dumps(
            {
                "runtime_sources": source_hashes,
                "native_binary_sha256": hashlib.sha256(
                    args.game.read_bytes()
                ).hexdigest(),
                "source_revision": env["COWORLD_SOURCE_REVISION"],
            },
            indent=2,
        )
        + "\n"
    )
    (output / "environment-keys.json").write_text(
        json.dumps({"base": sorted(clean), "game": sorted(env)}, indent=2)
    )

    def relay(client):
        path = client.request.path
        assert path.startswith("/player?slot=")
        stats = {
            "path": path,
            "received_player_frames": 0,
            "forwarded_player_frames": 0,
            "received_game_frames": 0,
            "forwarded_game_frames": 0,
            "ready_frames": 0,
            "withheld_stopped": [],
            "closures": [],
        }
        relay_stats.append(stats)
        try:
            with connect(
                f"ws://127.0.0.1:{game_port}" + path, open_timeout=3
            ) as upstream:

                def player_to_game():
                    try:
                        for payload in client:
                            stats["received_player_frames"] += 1
                            if isinstance(payload, str):
                                frame = json.loads(payload)
                                if (
                                    frame.get("type") == "stopped"
                                    and frame.get("stop_id") is not None
                                ):
                                    event("native_stopped", frame=frame, path=path)
                                    if args.case == "noack":
                                        stats["withheld_stopped"].append(frame)
                                        continue
                            elif payload == b"\x85":
                                stats["ready_frames"] += 1
                            upstream.send(payload)
                            stats["forwarded_player_frames"] += 1
                    except ConnectionClosed as error:
                        stats["closures"].append(str(error))
                    finally:
                        upstream.close()

                forward = threading.Thread(target=player_to_game, daemon=True)
                forward.start()
                try:
                    for payload in upstream:
                        stats["received_game_frames"] += 1
                        if isinstance(payload, str):
                            frame = json.loads(payload)
                            if frame.get("type") == "stop":
                                event("native_stop", frame=frame, path=path)
                        client.send(payload)
                        stats["forwarded_game_frames"] += 1
                except ConnectionClosed as error:
                    stats["closures"].append(str(error))
                finally:
                    client.close()
                    forward.join(timeout=2)
        except Exception as error:
            event("relay_error", error=repr(error))

    proxy = serve(relay, "127.0.0.1", 0)
    proxy_port = proxy.socket.getsockname()[1]
    proxy_owner = threading.Thread(target=proxy.serve_forever, daemon=True)
    proxy_owner.start()
    resources = (output / "resources.jsonl").open("x")
    observed = {
        "case": args.case,
        "source_revision": env["COWORLD_SOURCE_REVISION"],
        "real_provider_calls": 0,
    }
    try:
        assert shutil.disk_usage(output).free >= 2 * 2**30
        log = (output / "game.log").open("xb")
        logs.append(log)
        game = subprocess.Popen(
            [str(args.game.resolve())],
            cwd=ROOT,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        processes.append(game)
        event("native_game_started", pid=game.pid)
        while True:
            assert game.poll() is None, "game exited before actual HTTP readiness"
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{game_port}/healthz", timeout=1
                ) as response:
                    assert response.status == 200
                break
            except OSError:
                assert time.monotonic() - started < 20
                time.sleep(0.05)
        for slot, policy in enumerate(("formation", "swarm")):
            player_env = clean | {
                "PLAYER_SCRIPTED": policy,
                "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{proxy_port}/player?slot={slot}&token=local-finalization-{slot}",
            }
            log = (output / f"player-{slot}.log").open("xb")
            logs.append(log)
            processes.append(
                subprocess.Popen(
                    [str(args.player.resolve())],
                    cwd=ROOT,
                    env=player_env,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                )
            )
        seen_results = False
        while game.poll() is None:
            elapsed = time.monotonic() - started
            size = sum(p.stat().st_size for p in output.rglob("*") if p.is_file())
            free = shutil.disk_usage(output).free
            assert elapsed <= 240 and size <= 128 * 2**20 and free >= 2 * 2**30
            if not seen_results and (output / "results.json").exists():
                seen_results = True
                event("public_results_observed")
            resources.write(
                json.dumps(
                    {
                        "elapsed_s": elapsed,
                        "retained_bytes": size,
                        "free_bytes": free,
                        "ready_frames": sum(s["ready_frames"] for s in relay_stats),
                    }
                )
                + "\n"
            )
            resources.flush()
            time.sleep(0.05)
        event("native_game_exited", exit=game.returncode)
        observed.update(
            native_exit=game.returncode,
            public_results=(output / "results.json").exists(),
            public_replay=(output / "public.bitreplay").exists(),
            elapsed_s=time.monotonic() - started,
        )
        local = list(temporary.glob("cogball-replay-*.bitreplay"))
        assert len(local) == 1, local
        summary_cmd = [
            os.sys.executable,
            str(ROOT / "tools/replay_summary.py"),
            str(local[0]),
        ]
        summary = json.loads(
            subprocess.check_output(summary_cmd, cwd=ROOT, env=clean, timeout=20)
        )
        (output / "native-replay-summary.json").write_text(
            json.dumps(summary, indent=2) + "\n"
        )
        observed["native_replay_summary"] = summary
        assert summary["results"] is not None, "native match did not complete"
        assert (
            summary["results"]["reason"] == "complete"
            and summary["results"]["endRule"] == "full_time"
        ), summary["results"]
        assert len(summary["directives"]) == 80 and {
            d["turn"] for d in summary["directives"]
        } == set(range(40))
        assert len(relay_stats) == 2 and all(
            s["ready_frames"] > 4800 for s in relay_stats
        )
        if args.case == "noack":
            assert all(len(s["withheld_stopped"]) == 1 for s in relay_stats)
        else:
            assert all(not s["withheld_stopped"] for s in relay_stats)
        assert observed["public_results"] and observed["public_replay"], (
            "complete native match lost public artifacts"
        )
        assert game.returncode == 0
        results = json.loads((output / "results.json").read_text())
        observed["results"] = results
        assert results == summary["results"]
        assert (output / "public.bitreplay").read_bytes() == local[0].read_bytes()
        finalization = []
        for line in (output / "game.log").read_text().splitlines():
            if line.startswith("cogball finalization: "):
                finalization.append(json.loads(line.split(": ", 1)[1]))
        observed["finalization_stages"] = finalization
        assert finalization[-1]["stage"] == "results_published"
        assert finalization[-1]["elapsed_ms"] < 5000
        stage_names = [row["stage"] for row in finalization]
        assert stage_names.index("replay_published") < stage_names.index(
            "results_start"
        )
        if args.case in ("private-slow", "private503"):
            assert (output / "attempted-private-upload.jsonl").exists()
            assert (
                "private_publication_failed" in stage_names
                and "private_published" not in stage_names
            )
            failed = next(
                row
                for row in finalization
                if row["stage"] == "private_publication_failed"
            )
            assert failed["remaining_ms"] > 0
            if args.case == "private-slow":
                assert failed["elapsed_ms"] >= 4400
                assert not release_upload.is_set(), (
                    "fixture must withhold response until after native exit/results"
                )
            else:
                assert "503" in failed["detail"]
        else:
            assert stage_names.index("private_published") < stage_names.index(
                "results_start"
            )
        if args.case == "noack":
            rows = [
                json.loads(line)
                for line in (output / "trajectory.jsonl").read_text().splitlines()
            ]
            assert rows[-1]["status"] == "truncated"
        elif args.case == "ack":
            rows = [
                json.loads(line)
                for line in (output / "trajectory.jsonl").read_text().splitlines()
            ]
            assert rows[-1]["status"] == "completed"
        observed["status"] = "pass"
        print(
            json.dumps(
                {
                    key: observed[key]
                    for key in ("case", "status", "native_exit", "elapsed_s")
                }
            )
        )
    finally:
        release_upload.set()
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
        proxy.shutdown()
        artifact.shutdown()
        proxy_owner.join(timeout=2)
        artifact_owner.join(timeout=2)
        for log in logs:
            log.close()
        resources.close()
        (output / "observed.json").write_text(json.dumps(observed, indent=2) + "\n")
        (output / "relay.json").write_text(json.dumps(relay_stats, indent=2) + "\n")
        (output / "stage-events.json").write_text(json.dumps(events, indent=2) + "\n")


if __name__ == "__main__":
    main()
