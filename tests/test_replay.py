"""End-to-end: a real episode over the wasm sim, written as a replay.

The replay is parsed **strictly** — ``json.loads(path.read_bytes()
.decode("utf-8"))`` — and re-simulated from ``seed`` + ``controls_b64``
alone, reproducing every keyframe digest. That is the whole contract the
static viewer depends on.
"""

from __future__ import annotations

import base64
import json

import pytest
from conftest import record_scripted_episode, require_sim_wasm

from cogball import defaults
from cogball.replay import (BYTES_PER_TICK, PROTOCOL, TOP_LEVEL_KEYS, Replay,
                            ReplayError)
from cogball.sim import CogballSim


async def recorded(tmp_path, **kwargs):
    _result, data, doc, engine = await record_scripted_episode(**kwargs)
    path = tmp_path / "replay.json"
    path.write_bytes(data)
    return path, doc, engine


async def test_a_full_episode_writes_a_strictly_parseable_replay(tmp_path):
    path, results_doc, engine = await recorded(tmp_path)
    # strict: bytes -> utf-8 -> json, no leniency anywhere on the path
    document = json.loads(path.read_bytes().decode("utf-8"))

    assert document["protocol"] == PROTOCOL
    for key in TOP_LEVEL_KEYS:
        assert key in document, f"replay is missing {key}"
    assert document["results"] == results_doc
    assert document["results"]["reason"] in defaults.REASONS
    assert document["results"]["end_rule"] in defaults.END_RULES

    controls = base64.b64decode(document["controls_b64"], validate=True)
    assert len(controls) == document["tick_count"] * BYTES_PER_TICK
    assert document["tick_count"] == results_doc["final_tick"]
    assert document["ticks_per_second"] == defaults.TICKS_PER_SECOND
    assert len(document["names"]["robots"]) == defaults.NUM_ROBOTS
    assert document["names"]["players"] == ["daveey", "daveey-1"]
    assert document["names"]["aliases"] == list(defaults.ALIASES)


async def test_non_ascii_coach_text_survives_the_utf8_path(tmp_path):
    """Force a multi-byte say into the events and read the bytes back."""
    _result, data, _doc, engine = await record_scripted_episode(max_ticks=300)
    # the recorded stream already carries directive events; add one whose
    # text is non-ASCII and re-render through the same writer path
    from cogball.replay import ReplayWriter
    from conftest import make_config
    config = make_config(max_ticks=300)
    writer = ReplayWriter(config, "unknown", 0, {"players": ["a", "b"],
                                                 "aliases": ["Azure", "Magenta"],
                                                 "policy_kinds": ["scripted"] * 2,
                                                 "robots": []})
    writer.append_tick(0, bytes(BYTES_PER_TICK))
    writer.event({"type": "directive", "t": 0, "turn": 0, "seat": 0,
                  "alias": "Azure", "source": "llm", "latency_ms": 12,
                  "note": "presión alta \U0001F3C6",
                  "robots": [{"id": "AZ-1", "say": "¡vamos! \u26bd"}]})
    raw = writer.finalize({"reason": "complete"})
    reparsed = json.loads(raw.decode("utf-8"))
    assert reparsed["events"][0]["note"] == "presión alta \U0001F3C6"
    assert reparsed["events"][0]["robots"][0]["say"] == "¡vamos! \u26bd"


async def test_the_replay_resimulates_every_keyframe_digest(tmp_path):
    require_sim_wasm()
    path, _doc, _engine = await recorded(tmp_path)
    replay = Replay.parse(path.read_bytes())

    sim = CogballSim(seed=replay.doc["seed"],
                     first_kickoff_seat=replay.doc["first_kickoff_seat"])
    expected = {k["t"]: k["d"] for k in replay.doc["keyframes"]}
    assert expected, "no keyframes were written"
    for tick in range(replay.tick_count):
        if tick in expected:
            assert sim.state_digest() == expected[tick], \
                f"digest mismatch at keyframe {tick}"
        sim.set_controls(replay.tick_controls(tick))
        sim.step()
    assert sim.goals(0) == replay.doc["results"]["goals"][0]
    assert sim.goals(1) == replay.doc["results"]["goals"][1]


async def test_the_event_stream_shows_the_game_being_played(tmp_path):
    path, _doc, _engine = await recorded(tmp_path)
    document = json.loads(path.read_bytes().decode("utf-8"))
    kinds = [e["type"] for e in document["events"]]
    assert kinds[0] == "match_start"
    assert kinds[-1] == "end"
    for required in ("turn_start", "turn_end", "directive", "kick", "shot",
                     "touch"):
        assert required in kinds, f"no {required} events were recorded"

    turns = document["tick_count"] // document["turn_ticks"]
    for seat in range(defaults.SEATS):
        directives = [e for e in document["events"]
                      if e["type"] == "directive" and e["seat"] == seat]
        assert len(directives) == turns
        for directive in directives:
            assert directive["source"] in defaults.DIRECTIVE_SOURCES
            assert len(directive["robots"]) == defaults.ROBOTS_PER_SEAT
            assert directive["alias"] == defaults.ALIASES[seat]


async def test_the_replay_stays_well_under_the_size_budget(tmp_path):
    path, _doc, _engine = await recorded(tmp_path, max_ticks=7200)
    assert path.stat().st_size < 1_500_000, path.stat().st_size


def test_parse_rejects_broken_replays():
    with pytest.raises(ReplayError):
        Replay.parse(b"\xff\xfe not utf-8 json")
    with pytest.raises(ReplayError):
        Replay.parse(json.dumps({"protocol": "cogball/v0"}).encode())
    good = {k: None for k in TOP_LEVEL_KEYS}
    good.update({"protocol": PROTOCOL, "tick_count": 2,
                 "controls_b64": base64.b64encode(bytes(36)).decode()})
    Replay.parse(json.dumps(good).encode())          # this one is fine
    short = dict(good, tick_count=3)
    with pytest.raises(ReplayError):
        Replay.parse(json.dumps(short).encode())
    missing = {k: v for k, v in good.items() if k != "keyframes"}
    with pytest.raises(ReplayError):
        Replay.parse(json.dumps(missing).encode())
