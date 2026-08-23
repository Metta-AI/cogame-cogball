"""Directives: the coach's reply schema, tolerant parsing, and repair.

A directive is one turn's orders for a seat's three robots.  The same shape
comes out of an LLM reply and out of a scripted baseline, so both are
compiled by the identical control layer and are directly comparable.

**Truncation is on RUNE (Unicode codepoint) boundaries, never bytes.**  Every
string that can reach the replay goes through :func:`truncate_runes`, which
slices the decoded ``str`` and only then lets json/utf-8 encode it.  A
byte-truncated multi-byte character is exactly the bug that makes replay
bytes render in a browser but fail a strict JSON parser.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass, replace

from . import defaults


class DirectiveError(ValueError):
    """No usable directive could be recovered from a reply."""


def truncate_runes(text: str, limit: int) -> str:
    """Cut ``text`` to at most ``limit`` Unicode codepoints.

    Slicing a ``str`` is codepoint-wise in Python, so this can never split a
    multi-byte character; the caller encodes afterwards.  Slicing ``bytes``
    anywhere on the path to the replay is forbidden.
    """
    if not isinstance(text, str):
        text = "" if text is None else str(text)
    if len(text) <= limit:
        return text
    return text[:limit]


@dataclass(frozen=True)
class RobotOrder:
    robot_id: str
    role: str
    intent: str
    target: tuple[float, float]
    pass_to: str | None
    kick: str
    say: str

    def to_json(self) -> dict:
        return {
            "id": self.robot_id,
            "role": self.role,
            "intent": self.intent,
            "target": [round(self.target[0], 2), round(self.target[1], 2)],
            "pass_to": self.pass_to,
            "kick": self.kick,
            "say": self.say,
        }


@dataclass(frozen=True)
class Directive:
    seat: int
    note: str
    orders: tuple[RobotOrder, ...]
    source: str = "scripted"      # llm | scripted | fallback
    latency_ms: int = 0

    def to_json(self) -> dict:
        return {
            "note": self.note,
            "robots": [o.to_json() for o in self.orders],
        }


def clamp_target(x, y, fallback: tuple[float, float]) -> tuple[float, float]:
    """Finite, inside the pitch; anything else falls back to a known point."""
    fx, fy = fallback
    try:
        x = float(x)
        y = float(y)
    except (TypeError, ValueError):
        return fx, fy
    if not (math.isfinite(x) and math.isfinite(y)):
        return fx, fy
    return (max(-defaults.PITCH_X, min(defaults.PITCH_X, x)),
            max(-defaults.PITCH_Y, min(defaults.PITCH_Y, y)))


def make_order(robot_id: str, role: str, intent: str,
               target: tuple[float, float], pass_to: str | None,
               kick: str, say: str, seat: int,
               fallback_target: tuple[float, float]) -> RobotOrder:
    """Build a *legal* order from possibly-illegal parts (never raises)."""
    role = role if role in defaults.ROLES else defaults.DEFAULT_ROLE
    intent = intent if intent in defaults.INTENTS else defaults.DEFAULT_INTENT
    kick = kick if kick in defaults.KICK_MODES else defaults.DEFAULT_KICK
    mates = defaults.robot_ids_for_seat(seat)
    if pass_to not in mates or pass_to == robot_id:
        pass_to = None
    if intent == "pass" and pass_to is None:
        intent = "shoot"
    return RobotOrder(
        robot_id=robot_id,
        role=role,
        intent=intent,
        target=clamp_target(target[0], target[1], fallback_target),
        pass_to=pass_to,
        kick=kick,
        say=truncate_runes(say, defaults.SAY_MAX_RUNES),
    )


# -- tolerant parsing ------------------------------------------------------

def extract_json_object(text: str) -> dict:
    """Pull the outermost balanced ``{...}`` out of a model reply.

    Tolerates markdown fences and prose before/after the object, which is
    what Haiku produces when it ignores "reply must begin with '{'".
    """
    if not isinstance(text, str):
        raise DirectiveError("reply is not text")
    stripped = text.strip()
    if stripped.startswith("```"):
        # ```json\n{...}\n```  -> drop the fence lines
        lines = [ln for ln in stripped.splitlines()
                 if not ln.strip().startswith("```")]
        stripped = "\n".join(lines).strip()
    start = stripped.find("{")
    end = stripped.rfind("}")
    if start < 0 or end <= start:
        head = truncate_runes(stripped.replace("\n", " "), 160)
        raise DirectiveError(f"no JSON object in reply: {head}")
    try:
        payload = json.loads(stripped[start:end + 1])
    except (json.JSONDecodeError, ValueError) as exc:
        head = truncate_runes(stripped[start:end + 1].replace("\n", " "), 160)
        raise DirectiveError(f"reply is not JSON ({exc}): {head}") from exc
    if not isinstance(payload, dict):
        raise DirectiveError("reply JSON is not an object")
    return payload


def _robot_entries(payload: dict) -> list[dict]:
    """``robots`` as a list, accepting the id-keyed-object form too."""
    node = payload.get("robots")
    if isinstance(node, list):
        return [e for e in node if isinstance(e, dict)]
    if isinstance(node, dict):
        out = []
        for key, value in node.items():
            if isinstance(value, dict):
                entry = dict(value)
                entry.setdefault("id", key)
                out.append(entry)
        return out
    return []


def _coerce_target(node) -> tuple:
    """Accept ``[x, y]``, ``["1.5", "-2"]`` and ``{"x":…, "y":…}``."""
    if isinstance(node, dict):
        return node.get("x"), node.get("y")
    if isinstance(node, (list, tuple)) and len(node) >= 2:
        return _num(node[0]), _num(node[1])
    return None, None


def _num(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return value
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    return None


def _norm_id(value) -> str | None:
    if not isinstance(value, str):
        return None
    text = truncate_runes(value.strip(), defaults.ROBOT_ID_MAX_RUNES).upper()
    return text or None


def parse_directive(text: str, seat: int, world, previous: Directive | None,
                    fallback: Directive) -> Directive:
    """Parse one LLM reply into a legal directive, repairing what it can.

    Raises :class:`DirectiveError` only when no object with at least one
    usable robot entry can be recovered — that is what triggers the retry
    and then the scripted fallback.
    """
    payload = extract_json_object(text)
    entries = _robot_entries(payload)
    if not entries:
        raise DirectiveError("reply carried no robot entries")

    mates = defaults.robot_ids_for_seat(seat)
    by_id: dict[str, dict] = {}
    unmatched: list[dict] = []
    for entry in entries:
        rid = _norm_id(entry.get("id"))
        if rid in mates and rid not in by_id:
            by_id[rid] = entry
        else:
            unmatched.append(entry)
    if not by_id and not unmatched:
        raise DirectiveError("reply carried no robot entries")

    orders = []
    for slot, rid in enumerate(mates):
        entry = by_id.get(rid)
        if entry is None and unmatched:
            # Unmatched entries are assigned to the seat's robots by position.
            entry = unmatched.pop(0)
        robot_index = seat * defaults.ROBOTS_PER_SEAT + slot
        here = world.robots[robot_index]
        if entry is None:
            # Missing id: keep last turn's order for that robot, else the
            # scripted baseline's.
            source = previous or fallback
            orders.append(source.orders[slot])
            continue
        tx, ty = _coerce_target(entry.get("target"))
        orders.append(make_order(
            robot_id=rid,
            role=str(entry.get("role", "")).strip().lower(),
            intent=str(entry.get("intent", "")).strip().lower(),
            target=(tx, ty),
            pass_to=_norm_id(entry.get("pass_to")),
            kick=str(entry.get("kick", "")).strip().lower(),
            say=entry.get("say") if isinstance(entry.get("say"), str) else "",
            seat=seat,
            fallback_target=(here.x, here.y),
        ))

    note = payload.get("note")
    note = note if isinstance(note, str) else ""
    return Directive(
        seat=seat,
        note=truncate_runes(note, defaults.NOTE_MAX_RUNES),
        orders=tuple(orders),
        source="llm",
    )


def with_source(directive: Directive, source: str,
                latency_ms: int = 0) -> Directive:
    return replace(directive, source=source, latency_ms=latency_ms)
