"""The control layer: directive in, quantised motor bytes out."""

from __future__ import annotations

import math
import random
import re

import pytest
from conftest import REPO_ROOT, require_sim_wasm

from cogball import baselines, control, defaults
from cogball.control import Body, World, compile_controls, quantise
from cogball.directives import Directive, make_order


def world_at(ball=(0.0, 0.0, 0.0, 0.0), robots=None, tick=0) -> World:
    if robots is None:
        robots = [(-6.0 + 2.0 * i, (-1.0) ** i * 3.0) for i in range(6)]
    bodies = []
    for i, (x, y) in enumerate(robots):
        hx = 1.0 if defaults.seat_of_robot(i) == 0 else -1.0
        bodies.append(Body(x, y, 0.0, 0.0, hx, 0.0, 0.0, 0))
    return World(tick=tick, ball=Body(*ball), robots=tuple(bodies),
                 goals=(0, 0), last_touch_robot=-1, last_touch_seat=-1,
                 last_touch_tick=-1, freeze_until=0)


def directive_with(seat: int, intent: str, target=(0.0, 0.0),
                   kick="auto", pass_to=None, role="wing") -> Directive:
    ids = defaults.robot_ids_for_seat(seat)
    orders = tuple(
        make_order(rid, role, intent, target, pass_to, kick, "x", seat,
                   (0.0, 0.0))
        for rid in ids)
    return Directive(seat=seat, note="t", orders=orders)


def test_quantise_matches_the_documented_byte_range():
    assert quantise(0.0) == 0
    assert quantise(1.0) == 100
    assert quantise(-1.0) == -100
    assert quantise(5.0) == 100          # clamped
    assert quantise(-5.0) == -100
    assert quantise(0.005) == 1          # half away from zero, symmetric
    assert quantise(-0.005) == -1
    # non-finite is a bug upstream: refuse to actuate rather than slam the
    # motor to full (control.quantise documents this)
    assert quantise(float("nan")) == 0
    assert quantise(float("inf")) == 0
    assert quantise(float("-inf")) == 0


def test_every_intent_produces_finite_in_range_commands():
    rng = random.Random(20260822)
    for _ in range(200):
        ball = (rng.uniform(-20, 20), rng.uniform(-12.5, 12.5),
                rng.uniform(-30, 30), rng.uniform(-30, 30))
        robots = [(rng.uniform(-19, 19), rng.uniform(-11, 11))
                  for _ in range(6)]
        world = world_at(ball, robots)
        for intent in defaults.INTENTS:
            for seat in (0, 1):
                directive = directive_with(
                    seat, intent,
                    target=(rng.uniform(-20, 20), rng.uniform(-12.5, 12.5)),
                    pass_to=defaults.robot_ids_for_seat(seat)[2])
                for robot in defaults.robots_for_seat(seat):
                    order = directive.orders[robot % 3]
                    thrust, turn, kick = control.robot_controls(
                        world, robot, order)
                    assert math.isfinite(thrust) and math.isfinite(turn)
                    assert -1.0 <= thrust <= 1.0
                    assert -1.0 <= turn <= 1.0
                    assert kick in (0, 1)


def test_the_same_state_and_directive_always_yield_the_same_bytes():
    world = world_at((3.0, -1.0, 2.0, 0.5))
    directives = [directive_with(0, "shoot"), directive_with(1, "press")]
    first = compile_controls(world, directives)
    for _ in range(5):
        assert compile_controls(world, directives) == first


def test_kick_never_never_emits_a_kick():
    # robot 0 sitting right on the ball, facing it
    robots = [(0.0, 0.0)] + [(-15.0, 6.0 + i) for i in range(5)]
    world = world_at((0.9, 0.0, 0.0, 0.0), robots)
    never = directive_with(0, "chase", kick="never")
    auto = directive_with(0, "chase", kick="auto")
    assert control.robot_controls(world, 0, never.orders[0])[2] == 0
    assert control.robot_controls(world, 0, auto.orders[0])[2] == 1


def test_the_cooldown_blocks_a_kick():
    robots = [(0.0, 0.0)] + [(-15.0, 6.0 + i) for i in range(5)]
    world = world_at((0.9, 0.0, 0.0, 0.0), robots)
    auto = directive_with(0, "chase", kick="auto")
    assert control.robot_controls(world, 0, auto.orders[0])[2] == 1
    cooling = list(world.robots)
    cooling[0] = Body(0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 7)
    world = World(tick=0, ball=world.ball, robots=tuple(cooling),
                  goals=(0, 0), last_touch_robot=-1, last_touch_seat=-1,
                  last_touch_tick=-1, freeze_until=0)
    assert control.robot_controls(world, 0, auto.orders[0])[2] == 0


def test_hold_faces_the_ball_once_it_has_arrived():
    robots = [(5.0, 0.0)] + [(-15.0, 6.0 + i) for i in range(5)]
    world = world_at((5.0, 6.0, 0.0, 0.0), robots)
    order = directive_with(0, "hold", target=(5.0, 0.0)).orders[0]
    _thrust, turn, _kick = control.robot_controls(world, 0, order)
    # heading is +x, the ball is straight up: it must turn toward it
    assert turn != 0.0


def test_a_ball_on_the_boards_is_played_back_to_the_middle():
    """Without this the corners are an absorbing state (see control.py)."""
    ball = (-19.6, -12.1, 0.0, 0.0)
    robots = [(-19.0, -11.6)] + [(10.0, 3.0 + i) for i in range(5)]
    world = world_at(ball, robots)
    assert control.ball_on_the_boards(world)
    order = directive_with(0, "chase").orders[0]
    thrust, turn, _kick = control.robot_controls(world, 0, order)
    assert math.isfinite(thrust) and math.isfinite(turn)
    # and a ball in the middle of the pitch is untouched by the rule
    assert not control.ball_on_the_boards(world_at((0.0, 0.0, 0.0, 0.0)))
    # ... nor is one in front of goal, where a striker must still shoot
    assert not control.ball_on_the_boards(world_at((19.7, 0.5, 0.0, 0.0)))


def test_compile_controls_tolerates_a_missing_directive():
    world = world_at()
    ctl = compile_controls(world, [None, directive_with(1, "chase")])
    assert len(ctl) == defaults.NUM_ROBOTS * 3
    assert ctl[0:9] == bytes(9)          # seat 0 inert, not crashed


def test_the_python_mirror_of_the_c_constants_is_in_sync():
    """defaults.py restates a few sim/cogball_config.h values; they must agree."""
    header = (REPO_ROOT / "sim" / "cogball_config.h").read_text()

    def macro(name: str) -> float:
        match = re.search(
            rf"#define {name}\s+([-0-9.]+)", header)
        assert match, f"{name} not found in cogball_config.h"
        return float(match.group(1))

    assert defaults.PITCH_X == macro("CB_PITCH_X")
    assert defaults.PITCH_Y == macro("CB_PITCH_Y")
    assert defaults.GOAL_HALF_WIDTH == macro("CB_GOAL_HALF_WIDTH")
    assert defaults.PENALTY_X == macro("CB_PENALTY_X")
    assert defaults.PENALTY_Y == macro("CB_PENALTY_Y")
    assert defaults.ROBOT_R == macro("CB_ROBOT_R")
    assert defaults.BALL_R == macro("CB_BALL_R")
    assert defaults.KICK_RANGE == macro("CB_KICK_RANGE")
    assert defaults.KICK_DOT == macro("CB_KICK_DOT")
    assert defaults.ROBOT_MAX_SPEED == macro("CB_ROBOT_MAX_SPEED")
    assert defaults.BALL_MAX_SPEED == macro("CB_BALL_MAX_SPEED")
    assert defaults.NUM_ROBOTS == int(macro("CB_NUM_ROBOTS"))
    assert defaults.TICKS_PER_SECOND == int(macro("CB_TICKS_PER_SECOND"))
    assert defaults.DEFAULT_TURN_TICKS == int(macro("CB_TURN_TICKS"))


@pytest.mark.parametrize("baseline", defaults.BASELINES)
def test_the_bytes_the_sim_sees_round_trip(baseline):
    require_sim_wasm()
    from cogball.sim import CogballSim
    sim = CogballSim(seed=11, first_kickoff_seat=0)
    for _ in range(200):
        world = World.from_state(sim.state())
        ctl = compile_controls(
            world, [baselines.scripted_directive(baseline, world, 0),
                    baselines.scripted_directive(baseline, world, 1)])
        sim.set_controls(ctl)
        sim.step()
    assert not sim.fault()
