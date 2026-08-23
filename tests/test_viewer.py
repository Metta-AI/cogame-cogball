"""Viewer verification without a browser.

Three layers:

- **build outputs**: the five files the static bundle ships;
- **headless re-sim**: the node harness loads a real recorded replay into
  ``build/viewer_core.js`` (the emscripten build of the SAME physics core),
  re-simulates to the end, and must reproduce the recorded digests and land
  every seek exactly; malformed documents and action logs are rejected;
- **static assertions** on the chrome: the ``coworld-replay`` postMessage
  bridge (including ``tell("ready")``, which the platform greps the served
  JS for), the added nodes, and the 360 px legibility rules.
"""

from __future__ import annotations

import json
import shutil
import subprocess

import pytest
from conftest import (HARNESS, REPO_ROOT, record_scripted_episode,
                      require_viewer_core, require_viewer_dist)

INDEX = REPO_ROOT / "viewer" / "index.html"
SHELL = REPO_ROOT / "viewer" / "static_replay.js"

BUNDLE_FILES = ("index.html", "static_replay.js", "sim_sha.js",
                "cogball_viewer.js", "cogball_viewer.wasm")


def test_the_bundle_ships_exactly_the_five_files_the_platform_serves():
    dist = require_viewer_dist()
    for name in BUNDLE_FILES:
        path = dist / name
        assert path.exists(), f"viewer/dist/{name} missing"
        assert path.stat().st_size > 64, f"viewer/dist/{name} is trivial"


@pytest.mark.slow
async def test_the_headless_core_reproduces_a_recorded_replay(tmp_path):
    core = require_viewer_core()
    node = shutil.which("node")
    if node is None:
        pytest.skip("node not on PATH")

    _result, data, _doc, _engine = await record_scripted_episode(max_ticks=900)
    path = tmp_path / "replay.json"
    path.write_bytes(data)
    document = json.loads(data.decode("utf-8"))

    proc = subprocess.run([node, str(HARNESS), str(core), str(path)],
                          capture_output=True, text=True, timeout=600)
    assert proc.returncode == 0, f"harness failed:\n{proc.stderr}"
    out = json.loads(proc.stdout)

    # malformed documents and action logs are all refused
    assert out["malformed"] == {
        "badProtocol": True, "badBase64Length": True,
        "truncatedJson": True, "tickCountMismatch": True,
        "raggedLog": -1, "emptyLog": -1}

    assert out["total"] == document["tick_count"]
    assert out["headerTickCount"] == document["tick_count"]
    assert out["digests"] == [[k["t"], k["d"]] for k in document["keyframes"]]
    assert out["goals"] == document["results"]["goals"]

    # seeks land exactly, and seek-to-end reproduces the walked-to-end state
    assert out["midTick"] == document["tick_count"] // 2
    assert out["endTick"] == document["tick_count"]
    assert out["seekEndDigest"] == out["endDigest"]
    assert out["playingAtEnd"] == 0
    assert out["playAtEndRefused"] == 1

    # transport cadence: 1x is real time (one tick per 33.3 ms of wall
    # clock), a 5 s callback clamps to 100 ms, paused advances nothing
    assert [out["dt16a"], out["dt16b"], out["dt16c"]] == [0, 0, 1]
    assert out["dtClamped"] == 3
    assert out["pausedTicks"] == 0
    assert out["fastTicks"] > 100


def test_the_shell_carries_the_coworld_replay_bridge():
    shell = SHELL.read_text()
    assert 'src: "coworld-replay"' in shell
    assert 'tell("loading")' in shell
    assert 'tell("error"' in shell
    assert 'tell("ready")' in shell
    # ready must be reported after a drawn frame, not after a parsed payload
    assert shell.count("requestAnimationFrame") >= 2
    assert "window.parent.postMessage(envelope" in shell
    assert "AbortController" in shell
    assert "FETCH_TIMEOUT_MS" in shell


def test_the_shell_reads_the_replay_url_and_falls_back_to_local_mode():
    shell = SHELL.read_text()
    assert 'get("replay")' in shell
    assert '"/replay-data"' in shell
    assert "sim_core_sha256" in shell        # mismatch warning
    assert "loading-retry" in shell          # a failure offers a retry


def test_the_chrome_has_the_starter_nodes_and_the_cogball_additions():
    index = INDEX.read_text()
    for node in ("id=\"stage\"", "id=\"canvas\"", "id=\"status\"",
                 "id=\"controls\"", "id=\"playpause\"", "id=\"speed\"",
                 "id=\"seek\"", "id=\"tickinfo\"", "id=\"endcard\"",
                 "id=\"warn\""):
        assert node in index, f"starter chrome node missing: {node}"
    for node in ("id=\"scorebug\"", "id=\"feed\"", "id=\"goalbanner\"",
                 "id=\"heat\""):
        assert node in index, f"cogball node missing: {node}"
    assert "<script src=\"static_replay.js\">" in index
    assert "<script src=\"sim_sha.js\">" in index
    assert "<script src=\"cogball_viewer.js\">" in index


def test_the_scorebug_stays_legible_at_360_pixels():
    index = INDEX.read_text()
    assert ".plate-name { flex: 1 1 auto; min-width: 3.2em" in index
    assert "@media (max-width: 640px)" in index
    # the secondary labels are the ones that go away first
    media = index.split("@media (max-width: 640px)", 1)[1]
    for label in ("#bug-turn", "#bug-poss", "#speedlabel"):
        assert label in media.split("}", 6)[0], \
            f"{label} is not hidden under 640px"
    assert "clamp(10px, 3.2vw, 15px)" in index


def test_real_player_names_are_spectator_side_only():
    """The pitch shows aliases and robot ids; the scorebug shows names."""
    shell = SHELL.read_text()
    assert "replay.names.players[0]" in shell
    assert "textContent" in shell
    assert "innerHTML" not in shell     # names are player-controlled data
    viewer_main = (REPO_ROOT / "sim" / "viewer_main.c").read_text()
    assert '"AZ-1"' in viewer_main and '"MG-1"' in viewer_main
    assert "names.players" not in viewer_main
