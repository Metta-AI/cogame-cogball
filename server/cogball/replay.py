"""Replay format ``cogball/v1``: self-sufficient, strict UTF-8 JSON.

*Deviation from the moba starter, deliberate:* moba writes a binary
``MOBA``-magic file.  cogball writes UTF-8 JSON, because the platform's
definition-of-done fetches the replay from S3 and requires valid UTF-8 JSON
with a matching ``protocol`` and a ``results.reason``, and the shared
``tools/ci/docker_smoke.sh`` defaults to ``SMOKE_REQUIRE_REPLAY_JSON=1``.
The bulk payload — the per-tick action log — rides as one base64 string, so
the file stays small and parseable.

``seed`` + ``first_kickoff_seat`` + ``controls_b64`` + the pinned physics
core reproduce the episode exactly; the per-30-tick ``keyframes`` carry the
state digest so the viewer (and the tests, and a human reading the JSON) can
verify the re-simulation and see the game without running wasm at all.
"""

from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path

from . import defaults
from .sim import DEFAULT_WASM_PATH

PROTOCOL = "cogball/v1"
FORMAT_VERSION = 1
BYTES_PER_TICK = defaults.NUM_ROBOTS * 3  # 18

TOP_LEVEL_KEYS = (
    "protocol", "format_version", "sim_core_sha256", "seed",
    "first_kickoff_seat", "config", "names", "ticks_per_second",
    "turn_ticks", "tick_count", "controls_b64", "keyframes", "events",
    "results",
)


class ReplayError(ValueError):
    """Malformed or unsupported replay bytes."""


def sim_core_sha256(wasm_path: str | Path = DEFAULT_WASM_PATH) -> str:
    """Hex sha256 of the sim wasm the episode ran on."""
    return hashlib.sha256(Path(wasm_path).read_bytes()).hexdigest()


def _r3(value: float) -> float:
    return round(float(value), 3)


class ReplayWriter:
    """Accumulates controls, keyframes and events; finalize() renders JSON.

    Everything is buffered in memory: a full match is 7 200 x 18 B of
    controls, 240 keyframes and a few thousand events — a few hundred KB.
    """

    def __init__(self, config, sim_sha: str, first_kickoff_seat: int,
                 names: dict):
        self._config = config
        self._sha = sim_sha
        self._first_kickoff_seat = int(first_kickoff_seat)
        self._names = names
        self._controls = bytearray()
        self._tick_count = 0
        self.keyframes: list[dict] = []
        self.events: list[dict] = []

    @property
    def tick_count(self) -> int:
        return self._tick_count

    def append_tick(self, tick: int, ctl: bytes) -> None:
        """Record one tick's quantised control bytes (exactly as fed in)."""
        if tick != self._tick_count:
            raise ValueError(
                f"non-sequential tick {tick}, expected {self._tick_count}")
        if len(ctl) != BYTES_PER_TICK:
            raise ValueError(
                f"controls must be {BYTES_PER_TICK} bytes, got {len(ctl)}")
        self._controls += ctl
        self._tick_count += 1

    def keyframe(self, tick: int, state, digest: int) -> None:
        robots = []
        for i in range(defaults.NUM_ROBOTS):
            base = 4 + i * 8
            robots.append([_r3(state[base + 0]), _r3(state[base + 1]),
                           _r3(state[base + 4]), _r3(state[base + 5])])
        self.keyframes.append({
            "t": int(tick),
            "d": int(digest) & 0xFFFFFFFF,
            "b": [_r3(state[0]), _r3(state[1])],
            "r": robots,
        })

    def event(self, record: dict) -> None:
        self.events.append(record)

    def document(self, results: dict) -> dict:
        return {
            "protocol": PROTOCOL,
            "format_version": FORMAT_VERSION,
            "sim_core_sha256": self._sha,
            "seed": self._config.seed,
            "first_kickoff_seat": self._first_kickoff_seat,
            "config": self._config.to_dict(),
            "names": self._names,
            "ticks_per_second": defaults.TICKS_PER_SECOND,
            "turn_ticks": self._config.turn_ticks,
            "tick_count": self._tick_count,
            "controls_b64": base64.b64encode(bytes(self._controls))
                                  .decode("ascii"),
            "keyframes": self.keyframes,
            "events": self.events,
            "results": results,
        }

    def finalize(self, results: dict) -> bytes:
        """The complete replay file.

        ``ensure_ascii=False`` on purpose: coach notes and robot chatter are
        real Unicode and must survive as UTF-8 bytes. Every string on this
        path was truncated on rune boundaries by directives.truncate_runes,
        so the bytes always decode.
        """
        return json.dumps(self.document(results), ensure_ascii=False,
                          separators=(",", ":")).encode("utf-8")


class Replay:
    """A parsed replay: validated document + per-tick control access."""

    def __init__(self, doc: dict, controls: bytes):
        self.doc = doc
        self.controls = controls
        self.tick_count = doc["tick_count"]

    @classmethod
    def parse(cls, data: bytes) -> "Replay":
        try:
            doc = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ReplayError(f"replay is not valid UTF-8 JSON: {exc}") from exc
        if not isinstance(doc, dict):
            raise ReplayError("replay is not a JSON object")
        if doc.get("protocol") != PROTOCOL:
            raise ReplayError(
                f"bad protocol {doc.get('protocol')!r}, expected {PROTOCOL!r}")
        missing = [k for k in TOP_LEVEL_KEYS if k not in doc]
        if missing:
            raise ReplayError(f"replay missing keys: {', '.join(missing)}")
        if not isinstance(doc.get("tick_count"), int):
            raise ReplayError("replay tick_count must be an integer")
        try:
            controls = base64.b64decode(doc["controls_b64"], validate=True)
        except Exception as exc:
            raise ReplayError(f"controls_b64 is not base64: {exc}") from exc
        expected = doc["tick_count"] * BYTES_PER_TICK
        if len(controls) != expected:
            raise ReplayError(
                f"controls are {len(controls)} bytes, expected {expected} "
                f"({doc['tick_count']} ticks x {BYTES_PER_TICK})")
        return cls(doc, controls)

    def tick_controls(self, tick: int) -> bytes:
        if not 0 <= tick < self.tick_count:
            raise IndexError(
                f"tick {tick} out of range 0..{self.tick_count - 1}")
        start = tick * BYTES_PER_TICK
        return self.controls[start:start + BYTES_PER_TICK]
