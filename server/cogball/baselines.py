"""Scripted baselines: `formation` (the default and certification player)
and `swarm` (the deliberately weaker second filler).

Both emit the *same* directive JSON on the same 5 s cadence an LLM coach
does, so their output is legal by construction and directly comparable —
and both are pure functions of the world state, which is what makes the
bounded-orders assertion in tests/test_baselines.py meaningful.
"""

from __future__ import annotations

import math

from . import defaults
from .directives import Directive, make_order


def scripted_directive(name: str, world, seat: int) -> Directive:
    """Directive for ``seat`` from the named baseline (unknown -> formation)."""
    if name == "swarm":
        return swarm(world, seat)
    return formation(world, seat)


def _dist(a, bx: float, by: float) -> float:
    return math.sqrt((a.x - bx) ** 2 + (a.y - by) ** 2)


def _sign(v: float) -> float:
    return 1.0 if v >= 0.0 else -1.0


def _deepest(world, seat: int) -> int:
    """Robot nearest its own goal line; ties break by ascending index."""
    goal_x = defaults.own_goal_x(seat)
    best, best_d = None, None
    for i in defaults.robots_for_seat(seat):
        d = abs(world.robots[i].x - goal_x)
        if best_d is None or d < best_d:
            best, best_d = i, d
    return best


def _nearest_to_ball(world, seat: int, exclude: set[int]) -> int:
    b = world.ball
    best, best_d = None, None
    for i in defaults.robots_for_seat(seat):
        if i in exclude:
            continue
        d = _dist(world.robots[i], b.x, b.y)
        if best_d is None or d < best_d:
            best, best_d = i, d
    return best


def _keeper_target(world, seat: int) -> tuple[float, float]:
    goal_x = defaults.own_goal_x(seat)
    ty = max(-2.6, min(2.6, world.ball.y / 3.0))
    return goal_x + 3.0 * defaults.attack_dir(seat), ty


def formation(world, seat: int) -> Directive:
    """Keeper on the arc, striker on the ball, third robot shuttling.

    This is the bundled certification player and the default when a seat
    sets neither PLAYER_PROMPT nor PLAYER_SCRIPTED.
    """
    b = world.ball
    attack = defaults.attack_dir(seat)
    goal_x = defaults.own_goal_x(seat)
    ids = defaults.robot_ids_for_seat(seat)

    keeper = _deepest(world, seat)
    striker = _nearest_to_ball(world, seat, {keeper})
    third = [i for i in defaults.robots_for_seat(seat)
             if i not in (keeper, striker)][0]

    ball_in_own_half = (b.x * attack) < 0.0
    orders = []
    for i in defaults.robots_for_seat(seat):
        slot = i % defaults.ROBOTS_PER_SEAT
        rid = ids[slot]
        me = world.robots[i]
        if i == keeper:
            role, intent = "keeper", "hold"
            target = _keeper_target(world, seat)
            say = "holding the arc"
        elif i == striker:
            role = "striker"
            if defaults.in_own_penalty_area(seat, b.x, b.y):
                intent, say = "clear", "getting it clear"
            elif (b.x * attack) > 0.0 or _dist(me, b.x, b.y) <= 6.0:
                intent, say = "shoot", "going for goal"
            else:
                intent, say = "chase", "closing on the ball"
            target = (b.x, b.y)
        elif ball_in_own_half:
            role, intent = "back", "hold"
            mid_x = (b.x + goal_x) * 0.5
            mid_y = b.y * 0.5 - _sign(b.y) * 1.5
            target = (mid_x, mid_y)
            say = "covering the middle"
        else:
            role, intent = "wing", "intercept"
            target = (b.x + 7.0 * attack, -_sign(b.y) * 5.0)
            say = "running the channel"
        orders.append(make_order(
            robot_id=rid, role=role, intent=intent, target=target,
            pass_to=None, kick="auto", say=say, seat=seat,
            fallback_target=(me.x, me.y)))

    return Directive(seat=seat, note="formation: keeper, striker, support",
                     orders=tuple(orders), source="scripted")


def swarm(world, seat: int) -> Directive:
    """Everyone chases. Loses to `formation`, which gives the ladder spread."""
    b = world.ball
    attack = defaults.attack_dir(seat)
    ids = defaults.robot_ids_for_seat(seat)
    deepest = _deepest(world, seat)
    ball_in_own_half = (b.x * attack) < 0.0

    orders = []
    for i in defaults.robots_for_seat(seat):
        slot = i % defaults.ROBOTS_PER_SEAT
        me = world.robots[i]
        if i == deepest and ball_in_own_half:
            role, intent = "back", "hold"
            target = _keeper_target(world, seat)
            say = "sitting in"
        else:
            role = "back" if i == deepest else "striker"
            intent = "chase"
            target = (b.x, b.y)
            say = "on the ball"
        orders.append(make_order(
            robot_id=ids[slot], role=role, intent=intent, target=target,
            pass_to=None, kick="auto", say=say, seat=seat,
            fallback_target=(me.x, me.y)))

    return Directive(seat=seat, note="swarm: everyone to the ball",
                     orders=tuple(orders), source="scripted")
