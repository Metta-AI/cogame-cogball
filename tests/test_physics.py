"""Physics unit tests against the wasmtime-hosted core.

Everything here is a property the design note states outright, checked
against the real wasm module rather than a Python model of it.
"""

from __future__ import annotations

import math

from conftest import require_sim_wasm

from cogball import defaults
from cogball.sim import EV_GOAL, EV_KICK, EV_POST, CogballSim

NO_CONTROLS = bytes(defaults.NUM_ROBOTS * 3)


def fresh(seed: int = 1, kickoff_seat: int = 0) -> CogballSim:
    require_sim_wasm()
    return CogballSim(seed=seed, first_kickoff_seat=kickoff_seat)


def park_robots(sim: CogballSim, x: float = -19.0, y: float = 11.0) -> None:
    """Stack every robot in a corner, out of the way of a ball experiment."""
    for i in range(defaults.NUM_ROBOTS):
        sim.debug_place_robot(i, x + 1.2 * i, y)


def ball(sim: CogballSim):
    state = sim.state()
    return state[0], state[1], state[2], state[3]


def robot(sim: CogballSim, i: int):
    base = 4 + i * 8
    s = sim.state()
    return s[base:base + 8]


def test_ball_fired_at_a_wall_never_tunnels():
    """30 m/s is 0.25 m per substep, comfortably inside the ball's radius."""
    sim = fresh()
    park_robots(sim)
    sim.debug_place_ball(0.0, 8.0, 30.0, 0.0)
    for _ in range(600):
        sim.set_controls(NO_CONTROLS)
        sim.step()
        bx, by, _, _ = ball(sim)
        assert abs(bx) <= defaults.PITCH_X + 2.0 + 1e-9
        assert abs(by) <= defaults.PITCH_Y + 1e-9
    assert not sim.fault()


def test_wall_bounce_reproduces_the_restitution():
    sim = fresh()
    park_robots(sim)
    sim.debug_place_ball(19.0, 8.0, 10.0, 0.0)
    for _ in range(30):
        sim.set_controls(NO_CONTROLS)
        sim.step()
        _, _, vx, _ = ball(sim)
        if vx < 0:
            break
    _, _, vx, _ = ball(sim)
    # restitution 0.80, minus a substep or two of the 0.6/s linear damping
    assert -8.1 < vx < -7.5, vx


def test_robot_robot_resolution_is_symmetric():
    """Mirror-image robots must produce a mirror-image outcome exactly."""
    sim = fresh()
    park_robots(sim, x=-19.0, y=-11.0)
    sim.debug_place_ball(0.0, -11.9, 0.0, 0.0)
    sim.debug_place_robot(0, -0.5, 6.0, 1.0, 0.0, 3.0, 0.0)
    sim.debug_place_robot(1, 0.5, 6.0, -1.0, 0.0, -3.0, 0.0)
    sim.set_controls(NO_CONTROLS)
    sim.step()
    a = robot(sim, 0)
    b = robot(sim, 1)
    assert a[0] == -b[0]          # positions mirror exactly
    assert a[1] == b[1]
    assert a[2] == -b[2]          # velocities mirror exactly
    assert a[3] == b[3]
    # equal masses, equal-and-opposite impulse: net x momentum stays zero
    assert abs(a[2] + b[2]) < 1e-12


def test_kick_sets_the_along_heading_speed_and_recoils_the_robot():
    sim = fresh()
    park_robots(sim, x=-19.0, y=-11.0)
    sim.debug_place_robot(0, 0.0, 0.0, 1.0, 0.0)
    sim.debug_place_ball(0.9, 0.0, 0.0, 0.0)
    ctl = bytearray(NO_CONTROLS)
    ctl[2] = 1
    sim.set_controls(bytes(ctl))
    sim.step()
    kicks = [e for e in sim.events() if int(e[0]) == EV_KICK]
    assert len(kicks) == 1
    # max(v_parallel, 0) + 9.0, exactly, along the heading
    assert kicks[0][6] == 9.0
    assert kicks[0][7] == 0.0
    # reaction: 0.45 * 9.0 / 6.0 = 0.675 m/s backwards (then substepped)
    assert robot(sim, 0)[2] < 0.0


def test_kick_respects_range_facing_and_cooldown():
    sim = fresh()
    park_robots(sim, x=-19.0, y=-11.0)
    ctl = bytearray(NO_CONTROLS)
    ctl[2] = 1

    # out of range
    sim.debug_place_robot(0, 0.0, 0.0, 1.0, 0.0)
    sim.debug_place_ball(2.0, 0.0, 0.0, 0.0)
    sim.set_controls(bytes(ctl))
    sim.step()
    assert not [e for e in sim.events() if int(e[0]) == EV_KICK]

    # in range but facing away
    sim.debug_place_robot(0, 0.0, 0.0, -1.0, 0.0)
    sim.debug_place_ball(1.0, 0.0, 0.0, 0.0)
    sim.set_controls(bytes(ctl))
    sim.step()
    assert not [e for e in sim.events() if int(e[0]) == EV_KICK]

    # in range and facing: fires, then the cooldown blocks the next tick
    sim.debug_place_robot(0, 0.0, 0.0, 1.0, 0.0)
    sim.debug_place_ball(1.0, 0.0, 0.0, 0.0)
    sim.set_controls(bytes(ctl))
    sim.step()
    assert [e for e in sim.events() if int(e[0]) == EV_KICK]
    sim.debug_place_ball(1.0, 0.0, 0.0, 0.0)
    sim.set_controls(bytes(ctl))
    sim.step()
    assert not [e for e in sim.events() if int(e[0]) == EV_KICK]


def test_goal_fires_on_the_plane_crossing_not_a_tick_early_or_late():
    sim = fresh()
    park_robots(sim, x=-19.0, y=-11.0)
    sim.debug_place_ball(18.0, 0.0, 8.0, 0.0)
    goal = None
    previous_x = 18.0
    for _ in range(120):
        previous_x = ball(sim)[0]
        sim.set_controls(NO_CONTROLS)
        sim.step()
        found = [e for e in sim.events() if int(e[0]) == EV_GOAL]
        if found:
            goal = found[0]
            break
    assert goal is not None, "the ball never reached the goal"
    assert previous_x < defaults.PITCH_X          # not one tick early
    assert goal[7] >= defaults.PITCH_X            # crossed the plane
    assert abs(goal[8]) <= defaults.GOAL_HALF_WIDTH
    assert int(goal[2]) == 0                      # Azure attacks +x
    assert sim.goals(0) == 1


def test_ball_on_a_post_bounces_and_reports_it():
    sim = fresh()
    park_robots(sim, x=-19.0, y=-11.0)
    sim.debug_place_ball(18.5, defaults.GOAL_HALF_WIDTH, 6.0, 0.0)
    hit = None
    for _ in range(60):
        sim.set_controls(NO_CONTROLS)
        sim.step()
        found = [e for e in sim.events() if int(e[0]) == EV_POST]
        if found:
            hit = found[0]
            break
    assert hit is not None, "the ball never touched the post"
    assert abs(hit[4]) == defaults.PITCH_X
    assert abs(hit[5]) == defaults.GOAL_HALF_WIDTH
    assert ball(sim)[2] < 6.0     # the post took pace off it


def test_kickoff_places_all_seven_bodies_where_the_note_says():
    for kickoff_seat in (0, 1):
        sim = fresh(seed=42, kickoff_seat=kickoff_seat)
        state = sim.state()
        assert (state[0], state[1], state[2], state[3]) == (0.0, 0.0, 0.0, 0.0)
        own = -1.0 if kickoff_seat == 0 else 1.0
        other_base = (1 - kickoff_seat) * defaults.ROBOTS_PER_SEAT
        base = kickoff_seat * defaults.ROBOTS_PER_SEAT
        assert robot(sim, base)[0] == own * 1.5
        assert robot(sim, base)[1] == 0.0
        assert robot(sim, other_base)[0] == -own * 3.0
        assert robot(sim, other_base)[1] == 0.0
        for slot, sign in ((1, 1.0), (2, -1.0)):
            wide = robot(sim, base + slot)
            assert wide[0] == own * 9.0
            assert abs(wide[1] - sign * 4.5) <= 0.25
            wide = robot(sim, other_base + slot)
            assert wide[0] == -own * 9.0
            assert abs(wide[1] - sign * 4.5) <= 0.25
        for i in range(defaults.NUM_ROBOTS):
            r = robot(sim, i)
            assert (r[2], r[3], r[6], r[7]) == (0.0, 0.0, 0.0, 0.0)
            expect = 1.0 if defaults.seat_of_robot(i) == 0 else -1.0
            assert (r[4], r[5]) == (expect, 0.0)


def test_a_goal_freezes_play_for_one_second_then_restarts():
    sim = fresh()
    park_robots(sim, x=-19.0, y=-11.0)
    sim.debug_place_ball(19.5, 0.0, 8.0, 0.0)
    while not sim.goals(0):
        sim.set_controls(NO_CONTROLS)
        sim.step()
    assert sim.frozen()
    frozen_ticks = 0
    while sim.frozen():
        sim.set_controls(NO_CONTROLS)
        sim.step()
        frozen_ticks += 1
    assert frozen_ticks == 30      # 1.0 s of kickoff freeze
    bx, by, bvx, bvy = ball(sim)
    assert (bx, by, bvx, bvy) == (0.0, 0.0, 0.0, 0.0)


def test_robots_stay_inside_the_pitch_and_the_ball_stays_in_the_arena():
    """Random-ish flailing for a while must never leave the world."""
    sim = fresh(seed=7)
    for tick in range(1200):
        ctl = bytearray(defaults.NUM_ROBOTS * 3)
        for i in range(defaults.NUM_ROBOTS):
            ctl[i * 3 + 0] = (100 - (tick * 37 + i * 11) % 200) & 0xFF
            ctl[i * 3 + 1] = (100 - (tick * 53 + i * 17) % 200) & 0xFF
            ctl[i * 3 + 2] = 1 if (tick + i) % 5 == 0 else 0
        sim.set_controls(bytes(ctl))
        sim.step()
        state = sim.state()
        assert abs(state[0]) <= 22.0 + 1e-9
        assert abs(state[1]) <= defaults.PITCH_Y + 1e-9
        for i in range(defaults.NUM_ROBOTS):
            r = state[4 + i * 8: 12 + i * 8]
            assert abs(r[0]) <= defaults.PITCH_X - defaults.ROBOT_R + 1e-9
            assert abs(r[1]) <= defaults.PITCH_Y - defaults.ROBOT_R + 1e-9
            assert math.isclose(math.hypot(r[4], r[5]), 1.0, rel_tol=1e-12)
            assert math.hypot(r[2], r[3]) <= defaults.ROBOT_MAX_SPEED + 1e-9
    assert not sim.fault()
