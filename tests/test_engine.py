"""The turn loop: batching, budgets, end conditions and degradation."""

from __future__ import annotations

import asyncio
import json
import time

import pytest
from conftest import StubSeat, make_config, require_sim_wasm

from cogball import defaults
from cogball.engine import TurnEngine, score_for
from cogball.llm import LlmClient
from cogball.replay import ReplayWriter
from cogball.sim import CogballSim

GOOD_REPLY = json.dumps({
    "note": "hold the shape",
    "robots": [{"id": rid, "role": "wing", "intent": "chase",
                "target": [0, 0], "pass_to": None, "kick": "auto",
                "say": "on it"} for rid in ("AZ-1", "AZ-2", "AZ-3")],
})


def reply_for(seat: int) -> str:
    ids = defaults.robot_ids_for_seat(seat)
    return json.dumps({
        "note": "hold the shape",
        "robots": [{"id": rid, "role": "wing", "intent": "chase",
                    "target": [0, 0], "pass_to": None, "kick": "auto",
                    "say": "on it"} for rid in ids],
    })


class RecordingClient(LlmClient):
    """Records the in-flight window of every call, per seat."""

    def __init__(self, delay=0.05, **kwargs):
        super().__init__(**kwargs)
        self.transport = "fake"
        self.disabled = False
        self._resolved = True
        self.delay = delay
        self.windows: list[tuple[float, float, str]] = []

    async def _complete(self, system, user):
        seat = 1 if "Magenta" in user else 0
        start = time.monotonic()
        await asyncio.sleep(self.delay)
        self.windows.append((start, time.monotonic(), user))
        return reply_for(seat)


class HungClient(LlmClient):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.transport = "fake"
        self.disabled = False
        self._resolved = True

    async def _complete(self, system, user):
        await asyncio.sleep(3600)
        return ""


def disabled_client() -> LlmClient:
    client = LlmClient()
    client.disabled = True
    client._resolved = True
    return client


def build(config, seats, client, sim=None, monotonic=time.monotonic):
    require_sim_wasm()
    first = config.seed & 1
    sim = sim or CogballSim(seed=config.seed, first_kickoff_seat=first)
    writer = ReplayWriter(config, "unknown", first, {
        "players": [p.name for p in config.players],
        "aliases": list(defaults.ALIASES), "policy_kinds": [], "robots": []})
    engine = TurnEngine(sim, config, seats, client, writer,
                        monotonic=monotonic, first_kickoff_seat=first)
    return engine, writer


def llm_seats():
    return [StubSeat(0, "daveey", prompt="press high", scripted=None),
            StubSeat(1, "daveey-1", prompt="sit deep", scripted=None)]


async def test_both_seats_are_queried_in_one_parallel_batch():
    config = make_config(max_ticks=300)
    client = RecordingClient(delay=0.08)
    engine, _ = build(config, llm_seats(), client)
    await engine.run()

    assert len(client.windows) >= 4      # two turns x two seats
    a, b = client.windows[0], client.windows[1]
    overlap = min(a[1], b[1]) - max(a[0], b[0])
    assert overlap > 0, (
        "the two seats' calls did not overlap: they were issued "
        "sequentially, which is what blows the 720 s play budget")
    assert engine.llm_turns == [2, 2]


async def test_a_hung_coach_costs_at_most_the_turn_budget():
    config = make_config(max_ticks=150, turn_budget_seconds=0.4)
    engine, writer = build(config, llm_seats(), HungClient())
    started = time.monotonic()
    result = await engine.run()
    elapsed = time.monotonic() - started
    assert elapsed < 3.0, elapsed
    assert result.reason == "complete"
    assert result.fallback_turns == (1, 1)
    causes = [e for e in writer.events if e["type"] == "fallback"]
    assert causes and all(c["cause"] == "timeout" for c in causes)


async def test_the_budget_guard_finishes_the_match_scripted():
    """It must end complete/full_time, not deadline."""
    config = make_config(max_ticks=600, turn_budget_seconds=12,
                         wall_clock_budget_seconds=20)
    # A clock that is already 0.5 s from tripping `elapsed + 2*budget`.
    ticks = iter([0.0] + [1.0] * 100000)
    engine, writer = build(config, llm_seats(), HungClient(),
                           monotonic=lambda: next(ticks))
    result = await engine.run()
    assert result.reason == "complete"
    assert result.end_rule == "full_time"
    guards = [e for e in writer.events if e["type"] == "budget_guard"]
    assert len(guards) == 1 and guards[0]["turn"] == 0
    assert result.fallback_turns == (4, 4)
    assert all(c["budget_guard"] == 4 for c in result.fallback_causes)


async def test_the_wall_clock_hard_stop_reports_deadline():
    config = make_config(max_ticks=7200, wall_clock_budget_seconds=690)
    clock = iter([0.0, 0.0] + [10.0] * 20 + [700.0] * 100000)
    engine, _ = build(config, [StubSeat(0, "a"), StubSeat(1, "b")],
                      disabled_client(), monotonic=lambda: next(clock))
    result = await engine.run()
    assert result.reason == "deadline"
    assert result.end_rule == "wall_clock"
    assert result.final_tick < config.max_ticks


class FaultingSim:
    """Wraps the real sim and trips its fault flag after N ticks."""

    def __init__(self, inner, after: int, raise_instead=False):
        self.inner = inner
        self.after = after
        self.raise_instead = raise_instead
        self.ticks = 0

    def __getattr__(self, name):
        return getattr(self.inner, name)

    def step(self):
        self.ticks += 1
        if self.ticks > self.after and self.raise_instead:
            raise RuntimeError("wasmtime trap")
        self.inner.step()

    def fault(self):
        return self.ticks > self.after or self.inner.fault()


@pytest.mark.parametrize("raise_instead", [False, True])
async def test_a_sim_fault_scores_a_draw_and_still_writes_a_replay(
        raise_instead):
    config = make_config(max_ticks=900)
    require_sim_wasm()
    inner = CogballSim(seed=config.seed, first_kickoff_seat=0)
    sim = FaultingSim(inner, after=40, raise_instead=raise_instead)
    engine, writer = build(config, [StubSeat(0, "a"), StubSeat(1, "b")],
                           disabled_client(), sim=sim)
    result = await engine.run()
    assert result.reason == "fault"
    assert result.end_rule == "sim_fault"
    assert result.scores == (0.5, 0.5)
    assert result.winner is None
    assert 0 < writer.tick_count < config.max_ticks   # partial replay


class RunawaySim:
    """Wraps the real sim and reports a five-goal lead after N ticks."""

    def __init__(self, inner, after: int):
        self.inner = inner
        self.after = after
        self.ticks = 0

    def __getattr__(self, name):
        return getattr(self.inner, name)

    def step(self):
        self.ticks += 1
        self.inner.step()

    def goals(self, seat):
        if self.ticks > self.after:
            return defaults.MERCY_GOAL_DIFFERENCE if seat == 0 else 0
        return self.inner.goals(seat)


async def test_mercy_ends_a_runaway_match_at_a_turn_boundary():
    config = make_config(max_ticks=7200)
    require_sim_wasm()
    inner = CogballSim(seed=config.seed, first_kickoff_seat=0)
    engine, _ = build(config, [StubSeat(0, "a"), StubSeat(1, "b")],
                      disabled_client(), sim=RunawaySim(inner, after=200))
    result = await engine.run()
    assert result.reason == "complete"
    assert result.end_rule == "mercy"
    assert abs(result.goals[0] - result.goals[1]) >= \
        defaults.MERCY_GOAL_DIFFERENCE
    # the rules ended it, so it ended cleanly on a turn boundary
    assert result.final_tick % config.turn_ticks == 0
    assert result.final_tick < config.max_ticks


async def test_a_disconnected_seat_plays_formation_and_revives():
    config = make_config(max_ticks=900)
    seats = llm_seats()
    seats[1].connected = False
    client = RecordingClient(delay=0.0)
    engine, writer = build(config, seats, client)

    original = engine._collect_directives

    async def collect(turn, tick, world, views):
        if turn == 4:
            seats[1].connected = True     # the seat comes back
        await original(turn, tick, world, views)

    engine._collect_directives = collect
    result = await engine.run()

    assert result.llm_turns[0] == 6                # seat 0 never dropped
    # Three strikes of grace, then the seat degrades to the scripted layer;
    # it revives the turn after it reconnects.
    assert result.fallback_turns[1] == 2
    assert result.llm_turns[1] == 4
    sources = [e["source"] for e in writer.events
               if e["type"] == "directive" and e["seat"] == 1]
    assert sources == ["llm", "llm", "fallback", "fallback", "llm", "llm"]


async def test_scores_always_sum_to_exactly_one():
    for goals in [(0, 0), (1, 0), (3, 0), (5, 0), (2, 4), (7, 7)]:
        s0 = score_for(goals, 0)
        s1 = 1.0 - s0
        assert s0 + s1 == 1.0
        assert 0.0 <= s0 <= 1.0
    assert score_for((3, 0), 0) == 1.0
    assert score_for((1, 0), 0) == pytest.approx(0.6666666, abs=1e-6)
    assert score_for((0, 0), 0) == 0.5


async def test_every_turn_pushes_a_view_to_every_seat():
    config = make_config(max_ticks=600)
    seats = [StubSeat(0, "a"), StubSeat(1, "b")]
    engine, _ = build(config, seats, disabled_client())
    await engine.run()
    for seat in seats:
        assert len(seat.pushed) == 4
        view = seat.pushed[0]["view"]
        # anonymous aliases only: no real player name reaches a seat
        blob = json.dumps(seat.pushed)
        assert "daveey" not in blob
        assert view["you"]["alias"] in defaults.ALIASES
        assert set(view) == {
            "turn", "of", "clock", "score", "you", "pitch", "ball",
            "your_robots", "their_robots", "last_turn", "your_last_directive"}
        assert len(view["your_robots"]) == 3
        assert len(view["their_robots"]) == 3
        # the opponent's coaching is never visible
        assert "last_role" not in view["their_robots"][0]
