"""Bounded-orders / legality assertion on the scripted baselines.

Both baselines are pure functions of the world state, so this is a real
property check rather than a smoke test: for hundreds of pseudo-random
worlds, the directive they emit must validate against the same reply schema
an LLM's must, and the controls it compiles to must be in range.

Plus: the two baselines are *ordered* — `formation` beats `swarm` — which is
what gives the ladder a spread instead of a wall of draws.
"""

from __future__ import annotations

import math
import random

import pytest
from conftest import require_sim_wasm

from cogball import baselines, defaults
from cogball.control import Body, World, compile_controls


def random_world(rng: random.Random) -> World:
    ball = Body(rng.uniform(-20, 20), rng.uniform(-12.5, 12.5),
                rng.uniform(-30, 30), rng.uniform(-30, 30))
    robots = []
    for i in range(defaults.NUM_ROBOTS):
        angle = rng.uniform(-1.0, 1.0)
        norm = math.sqrt(angle * angle + 1.0)
        robots.append(Body(
            rng.uniform(-19.4, 19.4), rng.uniform(-11.9, 11.9),
            rng.uniform(-7, 7), rng.uniform(-7, 7),
            1.0 / norm, angle / norm, rng.uniform(-6, 6),
            rng.randint(0, 12)))
    return World(tick=rng.randint(0, 7200), ball=ball, robots=tuple(robots),
                 goals=(rng.randint(0, 5), rng.randint(0, 5)),
                 last_touch_robot=rng.randint(-1, 5),
                 last_touch_seat=rng.randint(-1, 1),
                 last_touch_tick=0, freeze_until=0)


def assert_legal(directive, seat: int) -> None:
    ids = defaults.robot_ids_for_seat(seat)
    assert len(directive.orders) == defaults.ROBOTS_PER_SEAT
    assert [o.robot_id for o in directive.orders] == list(ids)
    assert len(directive.note) <= defaults.NOTE_MAX_RUNES
    for order in directive.orders:
        assert order.role in defaults.ROLES
        assert order.intent in defaults.INTENTS
        assert order.kick in defaults.KICK_MODES
        assert order.pass_to is None or (
            order.pass_to in ids and order.pass_to != order.robot_id)
        x, y = order.target
        assert math.isfinite(x) and math.isfinite(y)
        assert -defaults.PITCH_X <= x <= defaults.PITCH_X
        assert -defaults.PITCH_Y <= y <= defaults.PITCH_Y
        assert len(order.say) <= defaults.SAY_MAX_RUNES


@pytest.mark.parametrize("name", defaults.BASELINES)
def test_baselines_emit_legal_directives_and_bounded_controls(name):
    rng = random.Random(2026_08_22)
    for _ in range(500):
        world = random_world(rng)
        directives = []
        for seat in range(defaults.SEATS):
            directive = baselines.scripted_directive(name, world, seat)
            assert_legal(directive, seat)
            directives.append(directive)
        ctl = compile_controls(world, directives)
        assert len(ctl) == defaults.NUM_ROBOTS * 3
        for i in range(defaults.NUM_ROBOTS):
            thrust = int.from_bytes(ctl[i * 3:i * 3 + 1], "big", signed=True)
            turn = int.from_bytes(ctl[i * 3 + 1:i * 3 + 2], "big", signed=True)
            assert -100 <= thrust <= 100
            assert -100 <= turn <= 100
            assert ctl[i * 3 + 2] in (0, 1)


def test_baselines_are_pure_functions_of_the_world():
    rng = random.Random(7)
    world = random_world(rng)
    for name in defaults.BASELINES:
        first = baselines.scripted_directive(name, world, 0)
        for _ in range(3):
            assert baselines.scripted_directive(name, world, 0) == first


def test_formation_always_posts_a_keeper():
    rng = random.Random(99)
    for _ in range(200):
        world = random_world(rng)
        for seat in range(defaults.SEATS):
            directive = baselines.formation(world, seat)
            roles = [o.role for o in directive.orders]
            assert roles.count("keeper") == 1


def test_swarm_sends_everyone_at_the_ball_in_the_other_half():
    world = World(
        tick=0, ball=Body(12.0, 0.0, 0.0, 0.0),
        robots=tuple(Body(-3.0 + i, 1.0 * i, 0.0, 0.0) for i in range(6)),
        goals=(0, 0), last_touch_robot=-1, last_touch_seat=-1,
        last_touch_tick=-1, freeze_until=0)
    directive = baselines.swarm(world, 0)   # Azure attacks +x: their half
    assert [o.intent for o in directive.orders] == ["chase"] * 3


@pytest.mark.slow
def test_formation_beats_swarm_over_a_full_match():
    """The baselines are ordered, so the ladder has a spread."""
    require_sim_wasm()
    from cogball.sim import CogballSim
    sim = CogballSim(seed=42, first_kickoff_seat=0)
    for _ in range(7200):
        world = World.from_state(sim.state())
        sim.set_controls(compile_controls(
            world, [baselines.formation(world, 0),
                    baselines.swarm(world, 1)]))
        sim.step()
    assert not sim.fault()
    assert sim.goals(0) > sim.goals(1), \
        f"formation {sim.goals(0)} - {sim.goals(1)} swarm"
