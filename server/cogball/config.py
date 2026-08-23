"""Game config model for the Coworld runtime contract.

The config JSON arrives via ``COGAME_CONFIG_URI``.  ``players`` and
``tokens`` are parallel arrays in seat-slot order (the paintarena /
coworld-ctf convention the platform runner emits):

    {
      "seed": 2864434397,                     // optional; derived if absent
      "max_ticks": 7200,
      "turn_ticks": 150,
      "turn_budget_seconds": 12,
      "tick_deadline_ms": 1000,
      "player_connect_timeout_seconds": 90,
      "wall_clock_budget_seconds": 690,
      "num_agents": 2,                        // ladder metadata; must equal
                                              // the seat count if present
      "players": [{"name": "Azure"}, {"name": "Magenta"}],
      "tokens": ["token-0", "token-1"]
    }

A missing seed is derived once at parse time and recorded on the resolved
config, so the value the sim actually ran with always reaches the replay.
"""

from __future__ import annotations

import json
import math
import secrets
from dataclasses import dataclass
from pathlib import Path

from . import defaults


class ConfigError(ValueError):
    """Invalid or inconsistent game config."""


@dataclass(frozen=True)
class PlayerConfig:
    name: str


@dataclass(frozen=True)
class GameConfig:
    players: tuple[PlayerConfig, ...]
    tokens: tuple[str, ...]
    seed: int
    max_ticks: int
    turn_ticks: int
    turn_budget_seconds: float
    tick_deadline_ms: int
    player_connect_timeout_seconds: float
    # Engine hard stop (reason "deadline", end_rule "wall_clock"): keeps a
    # slow episode under the platform's 20-minute kill so results and the
    # partial replay are always written.
    wall_clock_budget_seconds: float

    @property
    def num_seats(self) -> int:
        return len(self.players)

    @property
    def total_turns(self) -> int:
        """Turns a full-length match contains (ceil, so a ragged tail counts)."""
        return (self.max_ticks + self.turn_ticks - 1) // self.turn_ticks

    @classmethod
    def from_dict(cls, data: dict) -> "GameConfig":
        if not isinstance(data, dict):
            raise ConfigError(
                f"config must be a JSON object, got {type(data).__name__}")

        players_raw = data.get("players")
        if not isinstance(players_raw, list) or not players_raw:
            raise ConfigError("config requires a non-empty 'players' array")
        players = []
        for i, entry in enumerate(players_raw):
            if not isinstance(entry, dict) \
                    or not isinstance(entry.get("name"), str) \
                    or not entry["name"]:
                raise ConfigError(
                    f"players[{i}] must be an object with a non-empty 'name'")
            players.append(PlayerConfig(name=entry["name"]))
        if len(players) != defaults.SEATS:
            raise ConfigError(
                f"cogball seats exactly {defaults.SEATS} players "
                f"(one trio each), got {len(players)}")

        tokens_raw = data.get("tokens")
        if not isinstance(tokens_raw, list) or \
                not all(isinstance(t, str) and t for t in tokens_raw):
            raise ConfigError(
                "config requires a 'tokens' array of non-empty strings")
        if len(tokens_raw) != len(players):
            raise ConfigError(
                f"tokens length {len(tokens_raw)} != players length "
                f"{len(players)}")

        num_agents = data.get("num_agents")
        if num_agents is not None:
            if not isinstance(num_agents, int) or isinstance(num_agents, bool):
                raise ConfigError(
                    f"num_agents must be an integer, got {num_agents!r}")
            if num_agents != len(players):
                raise ConfigError(
                    f"num_agents {num_agents} != the {len(players)} player "
                    "seats; the ladder would schedule the wrong game")

        max_ticks = _int_field(data, "max_ticks", defaults.DEFAULT_MAX_TICKS)
        if max_ticks <= 0:
            raise ConfigError(f"max_ticks must be positive, got {max_ticks}")

        turn_ticks = _int_field(
            data, "turn_ticks", defaults.DEFAULT_TURN_TICKS)
        if turn_ticks <= 0:
            raise ConfigError(f"turn_ticks must be positive, got {turn_ticks}")

        tick_deadline_ms = _int_field(
            data, "tick_deadline_ms", defaults.DEFAULT_TICK_DEADLINE_MS)
        if tick_deadline_ms <= 0:
            raise ConfigError(
                f"tick_deadline_ms must be positive, got {tick_deadline_ms}")

        turn_budget = _positive_number(
            data, "turn_budget_seconds",
            defaults.DEFAULT_TURN_BUDGET_SECONDS)
        connect_timeout = _non_negative_number(
            data, "player_connect_timeout_seconds",
            defaults.DEFAULT_PLAYER_CONNECT_TIMEOUT_SECONDS)
        budget = _positive_number(
            data, "wall_clock_budget_seconds",
            defaults.DEFAULT_WALL_CLOCK_BUDGET_SECONDS)

        seed = data.get("seed")
        if seed is None:
            seed = secrets.randbits(32)
        elif not isinstance(seed, int) or isinstance(seed, bool):
            raise ConfigError(f"seed must be an integer, got {seed!r}")
        # The sim consumes a u32; mask HERE so the canonical seed recorded
        # in results and the replay is the value the sim actually ran with.
        seed &= 0xFFFFFFFF

        return cls(
            players=tuple(players),
            tokens=tuple(tokens_raw),
            seed=seed,
            max_ticks=max_ticks,
            turn_ticks=turn_ticks,
            turn_budget_seconds=turn_budget,
            tick_deadline_ms=tick_deadline_ms,
            player_connect_timeout_seconds=connect_timeout,
            wall_clock_budget_seconds=budget,
        )

    @classmethod
    def from_file_uri(cls, uri: str) -> "GameConfig":
        """Parse a config from a local ``file://`` URI or plain path.

        Read and parse failures surface as ConfigError so the process can
        exit 2 with a clean message instead of a traceback.
        """
        path = uri.removeprefix("file://")
        try:
            raw = Path(path).read_text()
        except OSError as exc:
            raise ConfigError(f"cannot read config from {uri}: {exc}") from exc
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ConfigError(
                f"config at {uri} is not valid JSON: {exc}") from exc
        return cls.from_dict(data)

    def to_dict(self) -> dict:
        """Fully-resolved config for the replay.

        Tokens are deliberately excluded: replays are public artifacts,
        tokens are per-episode seat credentials.
        """
        return {
            "seed": self.seed,
            "max_ticks": self.max_ticks,
            "turn_ticks": self.turn_ticks,
            "turn_budget_seconds": self.turn_budget_seconds,
            "tick_deadline_ms": self.tick_deadline_ms,
            "player_connect_timeout_seconds":
                self.player_connect_timeout_seconds,
            "wall_clock_budget_seconds": self.wall_clock_budget_seconds,
            "players": [{"name": p.name} for p in self.players],
        }


def _int_field(data: dict, key: str, default: int) -> int:
    value = data.get(key, default)
    if not isinstance(value, int) or isinstance(value, bool):
        raise ConfigError(f"{key} must be an integer, got {value!r}")
    return value


def _number(data: dict, key: str, default: float) -> float:
    value = data.get(key, default)
    if not isinstance(value, (int, float)) or isinstance(value, bool) \
            or not math.isfinite(value):
        raise ConfigError(f"{key} must be a finite number, got {value!r}")
    return float(value)


def _positive_number(data: dict, key: str, default: float) -> float:
    value = _number(data, key, default)
    if value <= 0:
        raise ConfigError(f"{key} must be positive, got {value!r}")
    return value


def _non_negative_number(data: dict, key: str, default: float) -> float:
    value = _number(data, key, default)
    if value < 0:
        raise ConfigError(f"{key} must be non-negative, got {value!r}")
    return value
