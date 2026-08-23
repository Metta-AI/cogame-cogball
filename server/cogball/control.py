"""The deterministic control layer: directive -> per-tick motor bytes.

Both LLM directives and scripted directives are compiled by *this* code, so
the two policy kinds are strictly comparable: a coach picks a role, a target
point, an intent and a kick policy every 5 s, and this module is the 30 Hz
reflex layer that executes it.

It is deliberately NOT part of the determinism boundary.  Its output is
quantised to bytes (``int8`` thrust/turn, ``uint8`` kick) before it reaches
the sim, and those bytes are what the replay stores — so the browser viewer
never runs this code at all, it feeds the recorded bytes to the identical
physics core.  That removes the whole class of "the control layer was
reimplemented in the viewer and drifted" bugs.

Algorithm: docs/plans/2026-08-22-cogball-design.md, "The control layer".
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from . import defaults

CTL_BYTES = defaults.NUM_ROBOTS * 3


@dataclass(frozen=True)
class Body:
    x: float
    y: float
    vx: float
    vy: float
    hx: float = 1.0
    hy: float = 0.0
    omega: float = 0.0
    cooldown: int = 0

    @property
    def speed(self) -> float:
        return math.sqrt(self.vx * self.vx + self.vy * self.vy)


@dataclass(frozen=True)
class World:
    """A decoded snapshot of the sim's packed state buffer."""

    tick: int
    ball: Body
    robots: tuple[Body, ...]
    goals: tuple[int, int]
    last_touch_robot: int
    last_touch_seat: int
    last_touch_tick: int
    freeze_until: int

    @classmethod
    def from_state(cls, state) -> "World":
        ball = Body(state[0], state[1], state[2], state[3])
        robots = []
        for i in range(defaults.NUM_ROBOTS):
            base = 4 + i * 8
            robots.append(Body(
                state[base + 0], state[base + 1], state[base + 2],
                state[base + 3], state[base + 4], state[base + 5],
                state[base + 6], int(state[base + 7])))
        return cls(
            tick=int(state[58]),
            ball=ball,
            robots=tuple(robots),
            goals=(int(state[56]), int(state[57])),
            last_touch_robot=int(state[52]),
            last_touch_seat=int(state[53]),
            last_touch_tick=int(state[54]),
            freeze_until=int(state[55]),
        )


def quantise(u: float) -> int:
    """``round(clamp(u, -1, 1) * 100)`` as a signed byte value.

    Half-away-from-zero, so the mapping is symmetric (Python's banker's
    rounding would make +0.005 and -0.005 disagree in magnitude).
    """
    if not math.isfinite(u):
        u = 0.0
    u = max(-1.0, min(1.0, u))
    v = u * 100.0
    n = int(v + 0.5) if v >= 0.0 else -int(-v + 0.5)
    return max(-100, min(100, n))


def _unit(dx: float, dy: float) -> tuple[float, float]:
    d = math.sqrt(dx * dx + dy * dy)
    if d < 1e-12:
        return 0.0, 0.0
    return dx / d, dy / d


def _sign(v: float) -> float:
    return 1.0 if v >= 0.0 else -1.0


def steering_point(world: World, robot: int, order) -> tuple[float, float]:
    """The point this robot is trying to occupy this tick."""
    seat = defaults.seat_of_robot(robot)
    me = world.robots[robot]
    b = world.ball
    tx, ty = order.target
    gx = defaults.opponent_goal_x(seat)

    if order.intent == "chase":
        px, py = b.x, b.y
    elif order.intent == "intercept":
        dist = math.sqrt((b.x - me.x) ** 2 + (b.y - me.y) ** 2)
        tau = dist / (defaults.ROBOT_MAX_SPEED + b.speed)
        tau = max(0.0, min(1.5, tau))
        px, py = b.x + b.vx * tau, b.y + b.vy * tau
    elif order.intent == "hold":
        return tx, ty
    elif order.intent == "shoot":
        ux, uy = _unit(gx - b.x, 0.0 - b.y)
        px, py = b.x - ux * 0.90, b.y - uy * 0.90
    elif order.intent == "pass":
        mate = _teammate_index(order.pass_to)
        if mate is None or mate == robot:
            ux, uy = _unit(gx - b.x, 0.0 - b.y)
        else:
            t = world.robots[mate]
            ux, uy = _unit(t.x + t.vx * 0.5 - b.x, t.y + t.vy * 0.5 - b.y)
        px, py = b.x - ux * 0.90, b.y - uy * 0.90
    elif order.intent == "clear":
        cy = 10.0 if abs(b.y) < 0.5 else _sign(b.y) * 10.0
        ux, uy = _unit(0.0 - b.x, cy - b.y)
        px, py = b.x - ux * 0.90, b.y - uy * 0.90
    elif order.intent == "press":
        opp = _nearest_opponent_to_ball(world, seat)
        o = world.robots[opp]
        px, py = o.x + o.vx * 0.5, o.y + o.vy * 0.5
    else:  # unreachable: directives.py normalises the enum
        px, py = b.x, b.y

    # Every intent except hold blends the coach's target as a 20 % bias.
    return 0.8 * px + 0.2 * tx, 0.8 * py + 0.2 * ty


def _teammate_index(pass_to: str | None) -> int | None:
    if not pass_to:
        return None
    try:
        return defaults.ROBOT_IDS.index(pass_to)
    except ValueError:
        return None


def _nearest_opponent_to_ball(world: World, seat: int) -> int:
    b = world.ball
    best, best_d = None, None
    for i in defaults.robots_for_seat(1 - seat):
        r = world.robots[i]
        d = (r.x - b.x) ** 2 + (r.y - b.y) ** 2
        if best_d is None or d < best_d:
            best, best_d = i, d
    return best


# How close to the boards the ball has to be for the escape rule below.
# ~2 ball diameters: wide enough to catch a ball rolling along the wall,
# narrow enough that ordinary play is untouched.
BOARDS_BAND = 0.75


def ball_on_the_boards(world: World) -> bool:
    """Is the ball jammed against the walls, where nobody can get behind it?

    The pitch is walled and there is no out of play, so a ball in a corner
    is otherwise an ABSORBING state: robots have a bigger radius than the
    ball, so no robot centre can ever be on the corner side of it, every
    push drives it deeper, and a kick along the heading (which points at
    the ball) hammers it into the boards.  The goal mouth is excluded --
    a striker in front of goal must still shoot, not clear.
    """
    b = world.ball
    if abs(b.y) >= defaults.PITCH_Y - defaults.BALL_R - BOARDS_BAND:
        return True
    if abs(b.x) >= defaults.PITCH_X - defaults.BALL_R - BOARDS_BAND \
            and abs(b.y) > defaults.GOAL_HALF_WIDTH + 1.0:
        return True
    return False


def robot_controls(world: World, robot: int, order) -> tuple[float, float, int]:
    """Un-quantised ``(u_thrust, u_turn, kick)`` for one robot."""
    me = world.robots[robot]
    b = world.ball
    px, py = steering_point(world, robot, order)

    bdx, bdy = b.x - me.x, b.y - me.y
    ball_dist = math.sqrt(bdx * bdx + bdy * bdy)
    boards = ball_on_the_boards(world)

    dx, dy = px - me.x, py - me.y
    dist = math.sqrt(dx * dx + dy * dy)
    # A `hold` robot that has arrived faces the ball instead of the spot.
    if order.intent == "hold" and dist < 0.4:
        dx, dy = bdx, bdy
        dist = ball_dist
    elif boards and ball_dist <= defaults.KICK_RANGE:
        # Off the boards: aim at the middle of the pitch and strike, which
        # is the only direction that frees a ball pinned on the wall.
        ex, ey = _unit(-b.x, -b.y)
        dx, dy = ex * 2.0, ey * 2.0
        dist = 2.0

    if dist < 1e-6:
        u_turn = 0.0
        cross = 0.0
        dot = 1.0
        ux = uy = 0.0
    else:
        ux, uy = dx / dist, dy / dist
        cross = me.hx * uy - me.hy * ux
        dot = me.hx * ux + me.hy * uy
        if dot >= 0.0:
            u_turn = max(-1.0, min(1.0, 3.0 * cross))
        else:
            # Facing away: turn the short way through the back hemisphere.
            u_turn = 1.0 if cross >= 0.0 else -1.0

    u_thrust = max(0.0, min(1.0, dot)) * min(1.0, dist / 1.0)
    if dist < 0.25 and (me.vx * ux + me.vy * uy) > 0.5:
        u_thrust = -0.3  # brake onto the spot

    kick = 0
    if order.kick == "auto" and me.cooldown == 0 \
            and 0.0 < ball_dist <= defaults.KICK_RANGE:
        facing = (me.hx * bdx + me.hy * bdy) / ball_dist
        if facing >= defaults.KICK_DOT:
            kick = 1
            if order.intent in ("hold", "press") and not boards:
                # Holding or shadowing: never hoof the ball backwards,
                # away from the point the coach sent us to.
                tux, tuy = _unit(px - me.x, py - me.y)
                if tux * bdx + tuy * bdy < 0.0:
                    kick = 0
    return u_thrust, u_turn, kick


def compile_controls(world: World, directives) -> bytes:
    """The tick's 18 quantised control bytes for all six robots.

    ``directives`` is indexed by seat; each carries three orders in the
    seat's robot order.  A missing directive drives that seat's robots
    inert rather than raising — no failure mode leaves a robot unactuated.
    """
    out = bytearray(CTL_BYTES)
    for robot in range(defaults.NUM_ROBOTS):
        seat = defaults.seat_of_robot(robot)
        directive = directives[seat] if seat < len(directives) else None
        if directive is None:
            continue
        order = directive.orders[robot % defaults.ROBOTS_PER_SEAT]
        u_thrust, u_turn, kick = robot_controls(world, robot, order)
        out[robot * 3 + 0] = quantise(u_thrust) & 0xFF
        out[robot * 3 + 1] = quantise(u_turn) & 0xFF
        out[robot * 3 + 2] = 1 if kick else 0
    return bytes(out)


FROZEN_CONTROLS = bytes(CTL_BYTES)
