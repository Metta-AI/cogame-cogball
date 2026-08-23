"""The turn engine: 48 decision turns, 150 ticks each, one match.

Per turn the engine freezes the world, builds each seat's view, and collects
one directive per seat — **both seats' LLM calls go out as one parallel
batch** (``llm.LlmClient.decide_batch``), never sequentially.  Per tick it
compiles the active directives into quantised motor bytes, feeds them to the
wasm sim, drains the physics events, and keeps the score, the stats and the
replay.

Degrade, never hang.  Every wait is bounded (per-attempt LLM deadlines, one
outer ``wait_for`` per turn, the connect timeout, the done-send timeout, and
this engine's wall-clock hard stop).  A seat that never connects, that
disconnects, or whose coach times out plays the `formation` baseline; no
failure mode leaves a robot unactuated.
"""

from __future__ import annotations

import asyncio
import json
import sys
import time
from dataclasses import dataclass, field
from typing import Callable, Sequence

from . import baselines, defaults
from .control import FROZEN_CONTROLS, World, compile_controls
from .directives import Directive, parse_directive, truncate_runes, \
    with_source
from .llm import LlmRequest
from .sim import EV_GOAL, EV_KICK, EV_KICKOFF, EV_POST, EV_TOUCH

PROGRESS_INTERVAL_SECONDS = 30.0


@dataclass(frozen=True)
class EpisodeResult:
    reason: str
    end_rule: str
    winner: int | None
    scores: tuple[float, ...]
    win: tuple[bool, ...]
    goals: tuple[int, ...]
    final_tick: int
    final_turn: int
    shots: tuple[int, ...]
    shots_on_target: tuple[int, ...]
    saves: tuple[int, ...]
    passes_completed: tuple[int, ...]
    interceptions: tuple[int, ...]
    possession_ticks: tuple[int, ...]
    distance_m: tuple[float, ...]
    llm_turns: tuple[int, ...]
    fallback_turns: tuple[int, ...]
    fallback_causes: tuple[dict, ...]
    policy_kinds: tuple[str, ...]


@dataclass
class _TurnCounters:
    kicks: list = field(default_factory=lambda: [0, 0])
    shots: list = field(default_factory=lambda: [0, 0])
    possession: list = field(default_factory=lambda: [0, 0])
    goals: list = field(default_factory=list)


def score_for(goals: Sequence[int], seat: int) -> float:
    """Team zero-sum, margin sensitive; the two seats sum to exactly 1.0."""
    gd = goals[seat] - goals[1 - seat]
    return 0.5 + 0.5 * max(-1.0, min(1.0, gd / 3.0))


class TurnEngine:
    def __init__(self, sim, config, seats, llm_client, writer,
                 on_tick: Callable[[int], None] | None = None,
                 monotonic: Callable[[], float] = time.monotonic,
                 first_kickoff_seat: int = 0):
        if len(seats) != config.num_seats:
            raise ValueError(
                f"need {config.num_seats} seats, got {len(seats)}")
        self.sim = sim
        self.config = config
        self.seats = list(seats)
        self.llm = llm_client
        self.writer = writer
        self.on_tick = on_tick
        self._now = monotonic
        self.first_kickoff_seat = first_kickoff_seat

        n = config.num_seats
        self.directives: list[Directive | None] = [None] * n
        self.previous: list[Directive | None] = [None] * n
        self.shots = [0] * n
        self.shots_on_target = [0] * n
        self.saves = [0] * n
        self.passes_completed = [0] * n
        self.interceptions = [0] * n
        self.possession_ticks = [0] * n
        self.llm_turns = [0] * n
        self.fallback_turns = [0] * n
        self.fallback_causes = [dict.fromkeys(defaults.FALLBACK_CAUSES, 0)
                                for _ in range(n)]
        self.distance_m = [0.0] * defaults.NUM_ROBOTS
        self._strikes = [0] * n
        self._seat_dead = [False] * n
        self._budget_guard_turn: int | None = None
        self._turn_counters = _TurnCounters()
        self._touch_history: list[tuple[int, int]] = []
        self._last_touch_event_tick = [-999] * defaults.NUM_ROBOTS
        self._pending_shot: dict | None = None
        self._pending_pass: dict | None = None
        self._start = 0.0
        self.final_turn = 0

    # -- public ------------------------------------------------------------

    async def run(self) -> EpisodeResult:
        cfg = self.config
        sim = self.sim
        self._start = self._now()
        last_progress = self._start
        tick = 0
        reason, end_rule = "complete", "full_time"

        self._record({"type": "match_start", "t": 0,
                      "kickoff_seat": self.first_kickoff_seat,
                      "aliases": list(defaults.ALIASES)})

        while True:
            elapsed = self._now() - self._start
            if elapsed >= cfg.wall_clock_budget_seconds:
                reason, end_rule = "deadline", "wall_clock"
                print(f"wall-clock budget of "
                      f"{cfg.wall_clock_budget_seconds:g}s elapsed at tick "
                      f"{tick}; stopping with reason=deadline",
                      file=sys.stderr)
                break
            if tick >= cfg.max_ticks:
                reason, end_rule = "complete", "full_time"
                break
            if self._now() - last_progress >= PROGRESS_INTERVAL_SECONDS:
                last_progress = self._now()
                print(f"progress: tick {tick}/{cfg.max_ticks}, "
                      f"score {sim.goals(0)}-{sim.goals(1)}, "
                      f"elapsed {elapsed:.0f}s", file=sys.stderr)

            try:
                state = sim.state()
            except Exception as exc:
                reason, end_rule = "fault", "sim_fault"
                print(f"sim state read failed: {exc}", file=sys.stderr)
                break
            world = World.from_state(state)

            if tick % cfg.turn_ticks == 0:
                turn = tick // cfg.turn_ticks
                self._record({"type": "turn_start", "t": tick, "turn": turn,
                              "score": [sim.goals(0), sim.goals(1)],
                              "possession": self._possession(world, tick)})
                # Views are built BEFORE the directives are collected, so a
                # seat's `your_last_directive` is genuinely last turn's.
                views = [self.build_view(s, world, turn, tick)
                         for s in range(cfg.num_seats)]
                await self._collect_directives(turn, tick, world, views)
                await self._push_turn(turn, tick, views)
                self._turn_counters = _TurnCounters()

            if tick % defaults.TICKS_PER_SECOND == 0:
                self.writer.keyframe(tick, state, sim.state_digest())

            frozen = sim.frozen()
            ctl = FROZEN_CONTROLS if frozen \
                else compile_controls(world, self.directives)
            self.writer.append_tick(tick, ctl)

            try:
                sim.set_controls(ctl)
                sim.step()
                events = sim.events()
            except Exception as exc:
                reason, end_rule = "fault", "sim_fault"
                print(f"sim step failed: {type(exc).__name__}: {exc}",
                      file=sys.stderr)
                break
            if sim.fault():
                reason, end_rule = "fault", "sim_fault"
                print(f"sim invariant guard tripped at tick {tick}",
                      file=sys.stderr)
                break

            after = sim.state()
            self._accumulate(tick, state, after, events)
            tick += 1
            if self.on_tick is not None:
                self.on_tick(tick)

            if tick % cfg.turn_ticks == 0:
                turn = tick // cfg.turn_ticks - 1
                self.final_turn = turn + 1
                self._record({"type": "turn_end", "t": tick, "turn": turn,
                              "score": [sim.goals(0), sim.goals(1)]})
                if abs(sim.goals(0) - sim.goals(1)) \
                        >= defaults.MERCY_GOAL_DIFFERENCE:
                    reason, end_rule = "complete", "mercy"
                    break

        self.final_turn = max(self.final_turn,
                              (tick + cfg.turn_ticks - 1) // cfg.turn_ticks)
        result = self._build_result(reason, end_rule, tick)
        self._record({"type": "end", "t": tick, "reason": reason,
                      "end_rule": end_rule, "score": list(result.goals)})
        return result

    # -- directives --------------------------------------------------------

    def _uses_llm(self, seat: int) -> bool:
        return self.seats[seat].policy_kind == "llm"

    async def _collect_directives(self, turn: int, tick: int, world: World,
                                  views: list[dict]) -> None:
        cfg = self.config
        fallbacks = [baselines.formation(world, s)
                     for s in range(cfg.num_seats)]

        # Strike rule, in TURNS: a seat that is not connected at the turn
        # boundary strikes; STRIKE_LIMIT strikes marks it dead and it plays
        # `formation` until it reconnects.
        for seat, s in enumerate(self.seats):
            if s.connected:
                if self._seat_dead[seat]:
                    print(f"seat {seat} ({s.name}) revived at turn {turn}",
                          file=sys.stderr)
                self._strikes[seat] = 0
                self._seat_dead[seat] = False
            else:
                self._strikes[seat] += 1
                if self._strikes[seat] >= defaults.STRIKE_LIMIT \
                        and not self._seat_dead[seat]:
                    self._seat_dead[seat] = True
                    print(f"seat {seat} ({s.name}) marked dead at turn "
                          f"{turn} (strike rule); playing formation",
                          file=sys.stderr)

        # Budget guard: if two more full turn budgets would overrun the
        # engine's hard stop, finish the match on the scripted layer so the
        # episode ends complete/full_time rather than deadline.
        elapsed = self._now() - self._start
        if self._budget_guard_turn is None and \
                elapsed + 2 * cfg.turn_budget_seconds > \
                cfg.wall_clock_budget_seconds:
            self._budget_guard_turn = turn
            remaining = cfg.wall_clock_budget_seconds - elapsed
            self._record({"type": "budget_guard", "t": tick, "turn": turn,
                          "remaining_s": round(remaining, 1)})
            print(f"budget guard at turn {turn}: {remaining:.1f}s left; the "
                  f"rest of the match plays scripted", file=sys.stderr)

        guarded = self._budget_guard_turn is not None
        requests: list[LlmRequest | None] = [None] * cfg.num_seats
        skip_causes: list[str | None] = [None] * cfg.num_seats
        for seat in range(cfg.num_seats):
            if not self._uses_llm(seat):
                continue
            if guarded:
                skip_causes[seat] = "budget_guard"
                continue
            if self._seat_dead[seat]:
                skip_causes[seat] = "transport_error"
                continue
            requests[seat] = LlmRequest(
                seat=seat,
                user=(self.seats[seat].prompt or "") + "\n\n"
                     + json.dumps(views[seat], ensure_ascii=False),
                validate=self._validator(seat, world, fallbacks[seat]),
            )

        if any(r is not None for r in requests):
            results = await self.llm.decide_batch(
                requests, cfg.turn_budget_seconds)
        else:
            results = [None] * cfg.num_seats

        for seat in range(cfg.num_seats):
            directive = self._resolve_seat(
                seat, turn, tick, world, fallbacks[seat],
                results[seat] if results else None, skip_causes[seat])
            self.previous[seat] = self.directives[seat]
            self.directives[seat] = directive
            self._record({
                "type": "directive", "t": tick, "turn": turn, "seat": seat,
                "alias": defaults.ALIASES[seat], "source": directive.source,
                "latency_ms": directive.latency_ms, "note": directive.note,
                "robots": [o.to_json() for o in directive.orders],
            })

    def _resolve_seat(self, seat: int, turn: int, tick: int, world: World,
                      fallback: Directive, result,
                      skip_cause: str | None) -> Directive:
        if not self._uses_llm(seat):
            name = self.seats[seat].scripted or defaults.DEFAULT_BASELINE
            return baselines.scripted_directive(name, world, seat)

        if result is not None and result.ok:
            self.llm_turns[seat] += 1
            return with_source(result.value, "llm", result.latency_ms)

        # Every failed attempt is recorded; the seat plays the scripted move.
        cause = skip_cause or (
            result.cause if result is not None else "no_credentials")
        if cause == "skipped":
            cause = "no_credentials"
        failures = result.attempt_failures if result is not None else ()
        if failures:
            for attempt, fcause, detail in failures:
                self._record({
                    "type": "fallback", "t": tick, "turn": turn, "seat": seat,
                    "attempt": attempt, "cause": fcause,
                    "detail": truncate_runes(detail, defaults.DETAIL_MAX_RUNES),
                })
            cause = failures[-1][1]
        else:
            self._record({
                "type": "fallback", "t": tick, "turn": turn, "seat": seat,
                "attempt": 1, "cause": cause,
                "detail": truncate_runes(
                    result.detail if result is not None else
                    "coaching skipped for this turn",
                    defaults.DETAIL_MAX_RUNES),
            })
        self.fallback_turns[seat] += 1
        if cause in self.fallback_causes[seat]:
            self.fallback_causes[seat][cause] += 1
        return with_source(fallback, "fallback",
                           result.latency_ms if result is not None else 0)

    def _validator(self, seat: int, world: World, fallback: Directive):
        previous = self.directives[seat]

        def validate(text: str) -> Directive:
            return parse_directive(text, seat, world, previous, fallback)

        return validate

    # -- the per-seat view -------------------------------------------------

    def _possession(self, world: World, tick: int) -> str:
        if world.last_touch_robot < 0:
            return "loose"
        if tick - world.last_touch_tick > defaults.TICKS_PER_SECOND:
            return "loose"
        return defaults.ROBOT_IDS[world.last_touch_robot]

    def build_view(self, seat: int, world: World, turn: int,
                   tick: int) -> dict:
        """Exactly what a seat can see. Perfect information about the
        world; nothing at all about the opponent's coaching."""
        cfg = self.config
        b = world.ball
        attack = defaults.attack_dir(seat)
        goal_x = defaults.own_goal_x(seat)
        opp_x = defaults.opponent_goal_x(seat)
        counters = self._turn_counters

        def robot_view(i: int, own: bool) -> dict:
            r = world.robots[i]
            dist = ((r.x - b.x) ** 2 + (r.y - b.y) ** 2) ** 0.5
            out = {
                "id": defaults.ROBOT_IDS[i],
                "pos": [round(r.x, 2), round(r.y, 2)],
                "vel": [round(r.vx, 2), round(r.vy, 2)],
                "facing": [round(r.hx, 2), round(r.hy, 2)],
                "speed": round(r.speed, 2),
                "dist_to_ball": round(dist, 2),
            }
            if own:
                out["kick_ready"] = r.cooldown == 0
                last = self.directives[seat]
                slot = i % defaults.ROBOTS_PER_SEAT
                out["last_role"] = last.orders[slot].role if last else None
            return out

        total = counters.possession[0] + counters.possession[1]
        pct = int(round(100.0 * counters.possession[seat] / total)) \
            if total else 0
        played = tick / defaults.TICKS_PER_SECOND
        left = max(0, cfg.max_ticks - tick) / defaults.TICKS_PER_SECOND
        last_directive = self.directives[seat]
        return {
            "turn": turn,
            "of": cfg.total_turns,
            "clock": {"played_s": round(played, 1), "left_s": round(left, 1)},
            "score": {"you": world.goals[seat], "them": world.goals[1 - seat]},
            "you": {
                "alias": defaults.ALIASES[seat],
                "attacking_x": f"{opp_x:+.0f}",
                "defending_x": f"{goal_x:+.0f}",
            },
            "pitch": {
                "x_min": -defaults.PITCH_X, "x_max": defaults.PITCH_X,
                "y_min": -defaults.PITCH_Y, "y_max": defaults.PITCH_Y,
                "goal_half_width": defaults.GOAL_HALF_WIDTH,
                "your_penalty_area":
                    f"x {'<=' if seat == 0 else '>='} "
                    f"{goal_x + defaults.PENALTY_X * attack:+.0f}, "
                    f"|y| <= {defaults.PENALTY_Y:g}",
            },
            "ball": {
                "pos": [round(b.x, 2), round(b.y, 2)],
                "vel": [round(b.vx, 2), round(b.vy, 2)],
                "speed": round(b.speed, 2),
                "possession": self._possession(world, tick),
                "in_your_half": (b.x * attack) < 0.0,
            },
            "your_robots": [robot_view(i, True)
                            for i in defaults.robots_for_seat(seat)],
            "their_robots": [robot_view(i, False)
                             for i in defaults.robots_for_seat(1 - seat)],
            "last_turn": {
                "your_kicks": counters.kicks[seat],
                "their_kicks": counters.kicks[1 - seat],
                "your_shots": counters.shots[seat],
                "their_shots": counters.shots[1 - seat],
                "goals": list(counters.goals),
                "possession_pct_you": pct,
            },
            "your_last_directive":
                last_directive.to_json() if last_directive else None,
        }

    async def _push_turn(self, turn: int, tick: int,
                         views: list[dict]) -> None:
        for seat, s in enumerate(self.seats):
            directive = self.directives[seat]
            await s.push({
                "type": "turn", "turn": turn, "tick": tick,
                "view": views[seat],
                "directive_source":
                    directive.source if directive else "scripted",
            })

    # -- per-tick bookkeeping ---------------------------------------------

    def _record(self, event: dict) -> None:
        self.writer.event(event)

    def _accumulate(self, tick: int, before, after, events) -> None:
        # distance travelled this tick, per robot
        for i in range(defaults.NUM_ROBOTS):
            base = 4 + i * 8
            dx = after[base + 0] - before[base + 0]
            dy = after[base + 1] - before[base + 1]
            self.distance_m[i] += (dx * dx + dy * dy) ** 0.5

        last_seat = int(after[53])
        if 0 <= last_seat < len(self.possession_ticks):
            self.possession_ticks[last_seat] += 1
            self._turn_counters.possession[last_seat] += 1

        for ev in events:
            kind = int(ev[0])
            if kind == EV_KICK:
                self._on_kick(tick, ev)
            elif kind == EV_TOUCH:
                self._on_touch(tick, int(ev[1]))
            elif kind == EV_POST:
                self._record({"type": "post", "t": tick,
                              "post": [round(ev[4], 2), round(ev[5], 2)]})
            elif kind == EV_GOAL:
                self._on_goal(tick, ev)
            elif kind == EV_KICKOFF:
                self._record({"type": "kickoff", "t": tick,
                              "restart_for_seat": int(ev[3])})

    def _order_for(self, robot: int):
        seat = defaults.seat_of_robot(robot)
        directive = self.directives[seat]
        if directive is None:
            return None
        return directive.orders[robot % defaults.ROBOTS_PER_SEAT]

    def _on_kick(self, tick: int, ev) -> None:
        robot = int(ev[1])
        seat = int(ev[2])
        bvx, bvy = ev[6], ev[7]
        bx, by = ev[8], ev[9]
        order = self._order_for(robot)
        intent = order.intent if order else "chase"
        speed = (bvx * bvx + bvy * bvy) ** 0.5
        self._record({
            "type": "kick", "t": tick, "robot": defaults.ROBOT_IDS[robot],
            "seat": seat, "pos": [round(ev[4], 2), round(ev[5], 2)],
            "intent": intent, "ball_speed_after": round(speed, 2),
        })
        self._turn_counters.kicks[seat] += 1
        self._note_touch(tick, robot)

        # Shot / save bookkeeping: does the post-kick ray reach their goal?
        goal_x = defaults.opponent_goal_x(seat)
        if bvx != 0.0:
            t_star = (goal_x - bx) / bvx
            if t_star > 0.0:
                pred_y = by + bvy * t_star
                on_target = abs(pred_y) <= defaults.GOAL_HALF_WIDTH
                if on_target or abs(pred_y) <= 8.0:
                    self.shots[seat] += 1
                    self._turn_counters.shots[seat] += 1
                    self._record({
                        "type": "shot", "t": tick,
                        "robot": defaults.ROBOT_IDS[robot], "seat": seat,
                        "on_target": on_target,
                        "predicted_y": round(pred_y, 2),
                    })
                    if on_target:
                        self.shots_on_target[seat] += 1
                        self._pending_shot = {"tick": tick, "seat": seat,
                                              "robot": robot}
        if intent == "pass":
            self._pending_pass = {"tick": tick, "seat": seat, "robot": robot}

    def _on_touch(self, tick: int, robot: int) -> None:
        seat = defaults.seat_of_robot(robot)
        if tick - self._last_touch_event_tick[robot] >= \
                defaults.TOUCH_EVENT_EVERY:
            self._last_touch_event_tick[robot] = tick
            self._record({"type": "touch", "t": tick,
                          "robot": defaults.ROBOT_IDS[robot], "seat": seat})
        self._note_touch(tick, robot)

    def _note_touch(self, tick: int, robot: int) -> None:
        """Resolve pending shots and passes against the next distinct toucher."""
        if not self._touch_history or self._touch_history[-1][1] != robot:
            self._touch_history.append((tick, robot))
            if len(self._touch_history) > 64:
                del self._touch_history[:32]

        seat = defaults.seat_of_robot(robot)
        pending = self._pending_shot
        if pending is not None and robot != pending["robot"]:
            self._pending_shot = None
            if seat != pending["seat"]:
                world_state = self.sim.state()
                base = 4 + robot * 8
                if defaults.in_own_penalty_area(
                        seat, world_state[base + 0], world_state[base + 1]):
                    self.saves[seat] += 1
                    self._record({
                        "type": "save", "t": tick,
                        "robot": defaults.ROBOT_IDS[robot], "seat": seat,
                        "shot_tick": pending["tick"]})

        pending = self._pending_pass
        if pending is not None and robot != pending["robot"]:
            if tick - pending["tick"] <= defaults.PASS_WINDOW_TICKS:
                self._pending_pass = None
                if seat == pending["seat"]:
                    self.passes_completed[seat] += 1
                    self._record({
                        "type": "pass_completed", "t": tick,
                        "from": defaults.ROBOT_IDS[pending["robot"]],
                        "to": defaults.ROBOT_IDS[robot], "seat": seat,
                        "kick_tick": pending["tick"]})
                else:
                    self.interceptions[seat] += 1
                    self._record({
                        "type": "interception", "t": tick,
                        "robot": defaults.ROBOT_IDS[robot], "seat": seat,
                        "kick_tick": pending["tick"]})
            else:
                self._pending_pass = None

    def _on_goal(self, tick: int, ev) -> None:
        scorer_robot = int(ev[1])
        seat = int(ev[2])
        speed = ev[4]
        score = [int(ev[5]), int(ev[6])]
        assist = None
        if scorer_robot >= 0:
            cutoff = tick - defaults.ASSIST_WINDOW_TICKS
            scorer_seat = defaults.seat_of_robot(scorer_robot)
            for t, r in reversed(self._touch_history):
                if t < cutoff:
                    break
                if r != scorer_robot and \
                        defaults.seat_of_robot(r) == scorer_seat:
                    assist = defaults.ROBOT_IDS[r]
                    break
        self._pending_shot = None
        self._pending_pass = None
        turn = tick // self.config.turn_ticks
        self._record({
            "type": "goal", "t": tick, "turn": turn, "seat": seat,
            "scorer": defaults.ROBOT_IDS[scorer_robot]
            if scorer_robot >= 0 else None,
            "assist": assist, "ball_speed": round(speed, 2),
            "score_after": score,
        })
        self._turn_counters.goals.append({
            "tick": tick,
            "by": defaults.ROBOT_IDS[scorer_robot]
            if scorer_robot >= 0 else None,
            "for": "you" if seat == 0 else "them",
        })

    # -- result ------------------------------------------------------------

    def _build_result(self, reason: str, end_rule: str,
                      final_tick: int) -> EpisodeResult:
        n = self.config.num_seats
        try:
            goals = tuple(self.sim.goals(s) for s in range(n))
        except Exception:
            goals = tuple([0] * n)
        policy_kinds = tuple(s.policy_kind for s in self.seats)

        if reason == "fault":
            scores = tuple([0.5] * n)
            win = tuple([False] * n)
            winner = None
        else:
            score0 = score_for(goals, 0)
            # score(1) is derived so the two seats sum to EXACTLY 1.0.
            scores = (score0, 1.0 - score0)
            win = tuple(goals[s] - goals[1 - s] > 0 for s in range(n))
            if goals[0] > goals[1]:
                winner = 0
            elif goals[1] > goals[0]:
                winner = 1
            else:
                winner = None

        return EpisodeResult(
            reason=reason,
            end_rule=end_rule,
            winner=winner,
            scores=scores,
            win=win,
            goals=goals,
            final_tick=final_tick,
            final_turn=self.final_turn,
            shots=tuple(self.shots),
            shots_on_target=tuple(self.shots_on_target),
            saves=tuple(self.saves),
            passes_completed=tuple(self.passes_completed),
            interceptions=tuple(self.interceptions),
            possession_ticks=tuple(self.possession_ticks),
            distance_m=tuple(round(d, 1) for d in self.distance_m),
            llm_turns=tuple(self.llm_turns),
            fallback_turns=tuple(self.fallback_turns),
            fallback_causes=tuple(dict(c) for c in self.fallback_causes),
            policy_kinds=policy_kinds,
        )
