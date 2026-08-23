"""Server-contract defaults and seat/robot topology.

Physics constants live in ``sim/cogball_config.h`` and are shared by the sim
build and the viewer build so they can never drift.  The handful mirrored
here are the ones the Python control layer and the per-seat view need; they
are asserted equal to the C header by ``tests/test_control.py``.

Seat topology: seat 0 is **Azure** (robots ``AZ-1..3``, index 0..2), defends
the goal at x = -20 and attacks +x.  Seat 1 is **Magenta** (``MG-1..3``,
index 3..5), defends x = +20 and attacks -x.
"""

from __future__ import annotations

SEATS = 2
ROBOTS_PER_SEAT = 3
NUM_ROBOTS = SEATS * ROBOTS_PER_SEAT

ROBOT_IDS = ("AZ-1", "AZ-2", "AZ-3", "MG-1", "MG-2", "MG-3")
ALIASES = ("Azure", "Magenta")
# Per-robot hues (degrees) for the viewer's position-history tinting.
ROBOT_HUES = (190, 202, 214, 330, 342, 354)

TICKS_PER_SECOND = 30

# -- pitch (mirrors sim/cogball_config.h) ---------------------------------
PITCH_X = 20.0
PITCH_Y = 12.5
GOAL_HALF_WIDTH = 3.5
PENALTY_X = 14.0
PENALTY_Y = 7.0
ROBOT_R = 0.55
BALL_R = 0.35
KICK_RANGE = 1.35
KICK_DOT = 0.5
ROBOT_MAX_SPEED = 7.0
BALL_MAX_SPEED = 30.0

# -- config defaults ------------------------------------------------------
DEFAULT_MAX_TICKS = 7200            # 240 s = 4:00 of soccer
DEFAULT_TURN_TICKS = 150            # one decision turn = 5.0 s
DEFAULT_TURN_BUDGET_SECONDS = 12.0
DEFAULT_TICK_DEADLINE_MS = 1000
DEFAULT_PLAYER_CONNECT_TIMEOUT_SECONDS = 90.0
DEFAULT_WALL_CLOCK_BUDGET_SECONDS = 690.0

# Mirrors the manifest's episode_timeout_minutes. The platform kills the
# container at that point, losing results and the replay; the engine's
# 690 s hard stop and the 12 s turn budget are sized against it (see the
# wall-clock arithmetic in docs/plans/2026-08-22-cogball-design.md).
PLATFORM_EPISODE_TIMEOUT_MINUTES = 20

# -- LLM cadence ----------------------------------------------------------
LLM_ATTEMPT_SECONDS = (8.0, 3.5)    # first try, then one retry
LLM_MAX_OUTPUT_TOKENS = 900         # 400 truncates before the JSON closes
LLM_TEMPERATURE = 0.4

# Consecutive TURNS (not ticks) a seat may miss before it is marked dead;
# a dead seat keeps playing the scripted layer and revives on reconnect.
STRIKE_LIMIT = 3

# Per-seat bound on the final done broadcast: a client that stopped reading
# must never stall process exit.
DONE_SEND_TIMEOUT_SECONDS = 3.0

# -- vocabularies ---------------------------------------------------------
ROLES = ("keeper", "back", "wing", "striker")
INTENTS = ("chase", "intercept", "hold", "shoot", "pass", "clear", "press")
KICK_MODES = ("auto", "never")
BASELINES = ("formation", "swarm")

DEFAULT_ROLE = "wing"
DEFAULT_INTENT = "chase"
DEFAULT_KICK = "auto"
DEFAULT_BASELINE = "formation"

# -- string caps, in RUNES (never bytes) ----------------------------------
NOTE_MAX_RUNES = 160
SAY_MAX_RUNES = 48
ROBOT_ID_MAX_RUNES = 8
POLICY_LABEL_MAX_RUNES = 48
DETAIL_MAX_RUNES = 200
PROMPT_MAX_RUNES = 4000

# -- closed enums (triple-sync rule: results_schema + docker_smoke.sh) ----
REASONS = ("complete", "deadline", "fault")
END_RULES = ("full_time", "mercy", "wall_clock", "sim_fault", "host_error")
FALLBACK_CAUSES = ("timeout", "parse_error", "transport_error",
                   "no_credentials", "budget_guard")
DIRECTIVE_SOURCES = ("llm", "scripted", "fallback")

MERCY_GOAL_DIFFERENCE = 5
ASSIST_WINDOW_TICKS = 120
PASS_WINDOW_TICKS = 120
TOUCH_EVENT_EVERY = 6      # at most one touch record per robot per 6 ticks


def seat_of_robot(robot: int) -> int:
    """Seat that owns robot index ``robot`` (0-2 Azure, 3-5 Magenta)."""
    return robot // ROBOTS_PER_SEAT


def robots_for_seat(seat: int) -> range:
    """Robot indices controlled by ``seat``."""
    return range(seat * ROBOTS_PER_SEAT, (seat + 1) * ROBOTS_PER_SEAT)


def robot_ids_for_seat(seat: int) -> tuple[str, ...]:
    return tuple(ROBOT_IDS[i] for i in robots_for_seat(seat))


def attack_dir(seat: int) -> float:
    """+1 if the seat attacks +x (Azure), -1 otherwise."""
    return 1.0 if seat == 0 else -1.0


def own_goal_x(seat: int) -> float:
    """x of the goal this seat defends."""
    return -PITCH_X if seat == 0 else PITCH_X


def opponent_goal_x(seat: int) -> float:
    return PITCH_X if seat == 0 else -PITCH_X


def in_own_penalty_area(seat: int, x: float, y: float) -> bool:
    """The penalty area in front of the goal ``seat`` defends."""
    if abs(y) > PENALTY_Y:
        return False
    return x <= -PENALTY_X if seat == 0 else x >= PENALTY_X
