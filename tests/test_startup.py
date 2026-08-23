"""Process startup: a bad environment must fail cleanly, not traceback."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

from conftest import REPO_ROOT

ENTRY = [sys.executable, "-m", "cogball.server"]


def run(env_extra: dict, timeout: int = 30):
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join(
        [str(REPO_ROOT / "server"), str(REPO_ROOT)])
    env.pop("COGAME_CONFIG_URI", None)
    env.pop("COGAME_LOAD_REPLAY_URI", None)
    env.update(env_extra)
    return subprocess.run(ENTRY, capture_output=True, text=True, env=env,
                          cwd=str(REPO_ROOT), timeout=timeout)


def test_a_missing_config_uri_exits_2_with_a_clean_message():
    proc = run({})
    assert proc.returncode == 2
    assert "COGAME_CONFIG_URI is required" in proc.stderr
    assert "Traceback" not in proc.stderr


def test_an_unreadable_config_exits_2_with_a_clean_message(tmp_path):
    proc = run({"COGAME_CONFIG_URI": f"file://{tmp_path}/nope.json"})
    assert proc.returncode == 2
    assert "invalid config" in proc.stderr
    assert "Traceback" not in proc.stderr


def test_config_that_is_not_json_exits_2_with_a_clean_message(tmp_path):
    path = Path(tmp_path) / "config.json"
    path.write_text("{not json")
    proc = run({"COGAME_CONFIG_URI": f"file://{path}"})
    assert proc.returncode == 2
    assert "not valid JSON" in proc.stderr
    assert "Traceback" not in proc.stderr


def test_a_config_with_the_wrong_seat_count_exits_2(tmp_path):
    path = Path(tmp_path) / "config.json"
    path.write_text(json.dumps({
        "players": [{"name": "a"}, {"name": "b"}, {"name": "c"}],
        "tokens": ["t0", "t1", "t2"]}))
    proc = run({"COGAME_CONFIG_URI": f"file://{path}"})
    assert proc.returncode == 2
    assert "seats exactly 2 players" in proc.stderr
    assert "Traceback" not in proc.stderr


def test_num_agents_disagreeing_with_the_seat_count_exits_2(tmp_path):
    path = Path(tmp_path) / "config.json"
    path.write_text(json.dumps({
        "players": [{"name": "a"}, {"name": "b"}],
        "tokens": ["t0", "t1"], "num_agents": 6}))
    proc = run({"COGAME_CONFIG_URI": f"file://{path}"})
    assert proc.returncode == 2
    assert "num_agents 6" in proc.stderr
    assert "Traceback" not in proc.stderr


def test_a_corrupt_replay_in_replay_mode_exits_2(tmp_path):
    path = Path(tmp_path) / "replay.json"
    path.write_bytes(b"{\"protocol\": \"nope\"}")
    proc = run({"COGAME_LOAD_REPLAY_URI": f"file://{path}"})
    assert proc.returncode == 2
    assert "invalid replay" in proc.stderr
    assert "Traceback" not in proc.stderr


def test_the_player_entry_point_fails_cleanly_with_no_url():
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join(
        [str(REPO_ROOT / "server"), str(REPO_ROOT)])
    env.pop("COWORLD_PLAYER_WS_URL", None)
    env.pop("COGAMES_ENGINE_WS_URL", None)
    proc = subprocess.run(
        [sys.executable, "-m", "players.cogball_player"],
        capture_output=True, text=True, env=env, cwd=str(REPO_ROOT),
        timeout=30)
    assert proc.returncode == 1
    assert "no websocket URL" in proc.stderr
    assert "Traceback" not in proc.stderr


def test_the_image_declares_both_role_shims():
    """The two /bin entrypoints the manifest and policies.json name.

    The docker smoke proves they are executable inside the real image; this
    keeps the Dockerfile and the manifest from drifting apart in a diff.
    """
    dockerfile = (REPO_ROOT / "Dockerfile").read_text()
    assert "/bin/cogball" in dockerfile
    assert "/bin/cogball-player" in dockerfile
    assert "chmod +x /bin/cogball /bin/cogball-player" in dockerfile
    assert 'CMD ["/bin/cogball"]' in dockerfile
