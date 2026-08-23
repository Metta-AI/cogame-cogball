"""Tolerant parsing and repair of coach replies, and the retry/fallback path.

A model reply is untrusted text. Everything here is about recovering a legal
directive from a messy one — and about the rune-boundary truncation rule,
which is the difference between a replay that a browser renders and a replay
that a strict JSON parser rejects.
"""

from __future__ import annotations

import asyncio
import json

import pytest

from cogball import baselines, defaults
from cogball.control import Body, World
from cogball.directives import (Directive, DirectiveError, parse_directive,
                                truncate_runes)
from cogball.llm import LlmClient, LlmRequest


def a_world() -> World:
    robots = tuple(Body(-6.0 + 2.0 * i, (-1.0) ** i * 3.0, 0.0, 0.0)
                   for i in range(defaults.NUM_ROBOTS))
    return World(tick=0, ball=Body(1.0, 2.0, 0.0, 0.0), robots=robots,
                 goals=(0, 0), last_touch_robot=-1, last_touch_seat=-1,
                 last_touch_tick=-1, freeze_until=0)


def parse(text: str, seat: int = 0, previous=None) -> Directive:
    world = a_world()
    return parse_directive(text, seat, world, previous,
                           baselines.formation(world, seat))


GOOD = json.dumps({
    "note": "compact, keeper stays home",
    "robots": [
        {"id": "AZ-1", "role": "keeper", "intent": "hold",
         "target": [-17.0, 0.4], "pass_to": None, "kick": "auto",
         "say": "holding the arc"},
        {"id": "AZ-2", "role": "striker", "intent": "shoot",
         "target": [10, 0], "pass_to": None, "kick": "auto", "say": "go"},
        {"id": "AZ-3", "role": "wing", "intent": "intercept",
         "target": [4, -5], "pass_to": "AZ-2", "kick": "auto", "say": "wide"},
    ],
})


def test_a_clean_reply_parses():
    directive = parse(GOOD)
    assert [o.robot_id for o in directive.orders] == ["AZ-1", "AZ-2", "AZ-3"]
    assert directive.orders[0].intent == "hold"
    assert directive.source == "llm"


def test_prose_prefixed_json_is_recovered():
    directive = parse("Sure! Here is my directive:\n" + GOOD + "\nHope this helps.")
    assert directive.orders[1].intent == "shoot"


def test_fenced_json_is_recovered():
    directive = parse("```json\n" + GOOD + "\n```")
    assert directive.orders[1].intent == "shoot"


def test_robots_as_an_id_keyed_object_is_accepted():
    payload = {"note": "n", "robots": {
        "AZ-1": {"role": "keeper", "intent": "hold", "target": [-17, 0]},
        "AZ-2": {"role": "striker", "intent": "shoot", "target": [8, 1]},
        "AZ-3": {"role": "wing", "intent": "press", "target": [0, 0]},
    }}
    directive = parse(json.dumps(payload))
    assert [o.intent for o in directive.orders] == ["hold", "shoot", "press"]


def test_numeric_strings_in_target_are_accepted():
    payload = {"robots": [{"id": "AZ-1", "target": ["-3.5", " 2 "]}]}
    directive = parse(json.dumps(payload))
    assert directive.orders[0].target == (-3.5, 2.0)


def test_unknown_enums_degrade_to_the_documented_defaults():
    payload = {"robots": [{"id": "AZ-1", "role": "libero",
                           "intent": "nutmeg", "kick": "sometimes",
                           "target": [0, 0]}]}
    order = parse(json.dumps(payload)).orders[0]
    assert order.role == "wing"
    assert order.intent == "chase"
    assert order.kick == "auto"


def test_non_finite_or_missing_targets_fall_back_to_the_robot_position():
    world = a_world()
    payload = {"robots": [{"id": "AZ-1", "target": ["nan", 1]},
                          {"id": "AZ-2"},
                          {"id": "AZ-3", "target": [1e9, -1e9]}]}
    directive = parse(json.dumps(payload))
    assert directive.orders[0].target == (world.robots[0].x, world.robots[0].y)
    assert directive.orders[1].target == (world.robots[1].x, world.robots[1].y)
    # out of pitch is clamped, not discarded
    assert directive.orders[2].target == (defaults.PITCH_X, -defaults.PITCH_Y)


def test_extra_robot_entries_are_dropped_and_missing_ones_are_filled():
    payload = {"robots": [
        {"id": "AZ-1", "intent": "hold", "target": [-17, 0]},
        {"id": "AZ-2", "intent": "shoot", "target": [8, 0]},
        {"id": "AZ-3", "intent": "press", "target": [0, 0]},
        {"id": "AZ-9", "intent": "clear", "target": [0, 0]},
    ]}
    directive = parse(json.dumps(payload))
    assert len(directive.orders) == 3
    assert [o.robot_id for o in directive.orders] == ["AZ-1", "AZ-2", "AZ-3"]


def test_an_id_from_the_other_team_is_assigned_by_position():
    payload = {"robots": [{"id": "MG-1", "intent": "clear", "target": [0, 0]}]}
    directive = parse(json.dumps(payload), seat=0)
    assert directive.orders[0].robot_id == "AZ-1"
    assert directive.orders[0].intent == "clear"


def test_missing_ids_come_from_last_turn_then_from_formation():
    previous = parse(GOOD)
    payload = {"robots": [{"id": "AZ-2", "intent": "press", "target": [0, 0]}]}
    directive = parse(json.dumps(payload), previous=previous)
    # AZ-2 came from the reply, AZ-1 and AZ-3 from last turn
    assert directive.orders[1].intent == "press"
    assert directive.orders[0] == previous.orders[0]
    assert directive.orders[2] == previous.orders[2]


def test_pass_to_must_be_a_teammate_and_pass_degrades_to_shoot():
    payload = {"robots": [
        {"id": "AZ-1", "intent": "pass", "pass_to": "MG-2", "target": [0, 0]},
        {"id": "AZ-2", "intent": "pass", "pass_to": "AZ-2", "target": [0, 0]},
        {"id": "AZ-3", "intent": "pass", "pass_to": "AZ-1", "target": [0, 0]},
    ]}
    orders = parse(json.dumps(payload)).orders
    assert orders[0].pass_to is None and orders[0].intent == "shoot"
    assert orders[1].pass_to is None and orders[1].intent == "shoot"
    assert orders[2].pass_to == "AZ-1" and orders[2].intent == "pass"


def test_zero_robots_and_garbage_are_rejected():
    for text in ("", "no json here", "{}", '{"robots": []}',
                 '{"robots": "three of them"}', "not json {"):
        with pytest.raises(DirectiveError):
            parse(text)


def test_a_300_character_note_is_cut_to_160_runes():
    payload = {"note": "x" * 300,
               "robots": [{"id": "AZ-1", "target": [0, 0]}]}
    directive = parse(json.dumps(payload))
    assert len(directive.note) == defaults.NOTE_MAX_RUNES


def test_truncation_lands_on_a_rune_boundary_and_survives_a_strict_parser():
    """A 4-byte emoji straddling the 48-rune `say` cap.

    Slicing bytes here is the bug that makes a replay render in a browser
    but fail json.loads; slicing the str cannot.
    """
    say = "a" * 47 + "\U0001F3C6" + "b" * 10   # trophy at runes 47..48
    payload = {"robots": [{"id": "AZ-1", "target": [0, 0], "say": say}]}
    order = parse(json.dumps(payload)).orders[0]
    assert len(order.say) == defaults.SAY_MAX_RUNES
    assert order.say.endswith("\U0001F3C6")
    encoded = json.dumps({"say": order.say}, ensure_ascii=False).encode("utf-8")
    assert json.loads(encoded.decode("utf-8"))["say"] == order.say
    # ... and the naive byte slice really would have broken it
    naive = say.encode("utf-8")[:defaults.SAY_MAX_RUNES]
    with pytest.raises(UnicodeDecodeError):
        naive.decode("utf-8")


def test_truncate_runes_never_splits_a_codepoint():
    for limit in range(0, 12):
        cut = truncate_runes("\U0001F3C6" * 8, limit)
        assert len(cut) == min(limit, 8)
        cut.encode("utf-8").decode("utf-8")


# -- the retry / fallback path ------------------------------------------------

class FakeClient(LlmClient):
    """An LlmClient whose transport is a scripted list of replies."""

    def __init__(self, replies, delays=None):
        super().__init__(attempt_deadlines=(0.2, 0.1))
        self.replies = list(replies)
        self.delays = list(delays or [0.0] * len(replies))
        self.calls = 0
        self.disabled = False
        self.transport = "fake"
        self._resolved = True

    async def _complete(self, system, user):
        index = min(self.calls, len(self.replies) - 1)
        delay = self.delays[min(self.calls, len(self.delays) - 1)]
        self.calls += 1
        if delay:
            await asyncio.sleep(delay)
        reply = self.replies[index]
        if isinstance(reply, Exception):
            raise reply
        return reply


async def decide(client, validate):
    results = await client.decide_batch(
        [LlmRequest(seat=0, user="u", validate=validate)], 5.0)
    return results[0]


async def test_a_good_first_reply_needs_no_retry():
    client = FakeClient([GOOD])
    result = await decide(client, lambda t: parse(t))
    assert result.ok
    assert client.calls == 1
    assert result.attempts == 1


async def test_a_bad_reply_is_retried_exactly_once_then_falls_back():
    client = FakeClient(["not json", "still not json"])
    result = await decide(client, lambda t: parse(t))
    assert not result.ok
    assert client.calls == 2
    assert result.cause == "parse_error"
    assert len(result.attempt_failures) == 2


async def test_a_timeout_on_attempt_one_is_retried_once():
    client = FakeClient([GOOD, GOOD], delays=[5.0, 0.0])
    result = await decide(client, lambda t: parse(t))
    assert result.ok
    assert client.calls == 2
    assert result.attempt_failures[0][1] == "timeout"


async def test_a_transport_error_is_reported_as_such():
    client = FakeClient([RuntimeError("connection reset")] * 2)
    result = await decide(client, lambda t: parse(t))
    assert result.cause == "transport_error"
    assert "connection reset" in result.detail


async def test_no_credentials_falls_back_instantly_with_no_network():
    client = LlmClient()
    client._resolved = True
    client.disabled = True
    result = await decide(client, lambda t: parse(t))
    assert result.cause == "no_credentials"
    assert result.attempts == 0
