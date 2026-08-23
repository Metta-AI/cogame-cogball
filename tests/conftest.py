"""Shared test fixtures.

The wasm artefacts are built by ``sim/build_sim.sh`` and
``sim/build_viewer.sh``; locally they may be absent, in which case the tests
that need them skip with a clear message.  In CI they were just built, so
``COGBALL_REQUIRE_WASM_BUILD=1`` turns those skips into failures — a skipped
determinism gate is a gate that silently stopped gating.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "server"))
sys.path.insert(0, str(REPO_ROOT))

SIM_WASM = REPO_ROOT / "build" / "cogball_sim.wasm"
VIEWER_CORE_JS = REPO_ROOT / "build" / "viewer_core.js"
VIEWER_DIST = REPO_ROOT / "viewer" / "dist"
HARNESS = Path(__file__).parent / "viewer_core_harness.js"
GOLDEN = Path(__file__).parent / "data" / "golden_digests.json"


def _missing(what: str, how: str):
    message = f"{what} not built - run {how} first"
    if os.environ.get("COGBALL_REQUIRE_WASM_BUILD"):
        pytest.fail(message + " (COGBALL_REQUIRE_WASM_BUILD is set)")
    pytest.skip(message)


def require_sim_wasm() -> Path:
    if not SIM_WASM.exists():
        _missing("build/cogball_sim.wasm", "sim/build_sim.sh")
    return SIM_WASM


def require_viewer_core() -> Path:
    if not VIEWER_CORE_JS.exists():
        _missing("build/viewer_core.js", "sim/build_viewer.sh")
    return VIEWER_CORE_JS


def require_viewer_dist() -> Path:
    if not (VIEWER_DIST / "index.html").exists():
        _missing("viewer/dist", "sim/build_viewer.sh")
    return VIEWER_DIST


@pytest.fixture
def sim_wasm():
    return require_sim_wasm()


# -- shared episode recording -------------------------------------------------

class StubSeat:
    """A seat with no websocket: the engine only needs a policy and push()."""

    def __init__(self, slot: int, name: str, prompt: str = "",
                 scripted: str | None = "formation", connected: bool = True):
        self.slot = slot
        self.name = name
        self.alias = ("Azure", "Magenta")[slot]
        self.prompt = prompt
        self.scripted = scripted
        self.policy_label = scripted or "prompt"
        self.connected = connected
        self.pushed: list[dict] = []

    @property
    def policy_kind(self) -> str:
        return "llm" if self.prompt else "scripted"

    async def push(self, payload: dict) -> None:
        self.pushed.append(payload)


def make_config(**overrides):
    from cogball.config import GameConfig
    data = {
        "players": [{"name": "daveey"}, {"name": "daveey-1"}],
        "tokens": ["token-0", "token-1"],
        "seed": 42,
        "max_ticks": 900,
        "turn_ticks": 150,
        "turn_budget_seconds": 12,
        "tick_deadline_ms": 1000,
        "player_connect_timeout_seconds": 5,
        "wall_clock_budget_seconds": 180,
    }
    data.update(overrides)
    return GameConfig.from_dict(data)


async def record_scripted_episode(baselines=("formation", "swarm"),
                                  **config_overrides):
    """Run a real wasm episode with two scripted seats.

    Returns ``(result, replay_bytes, results_doc, engine)``.  Used by the
    determinism, replay and viewer tests, which all need a genuine recorded
    match rather than a synthetic action log.
    """
    from cogball.engine import TurnEngine
    from cogball.llm import LlmClient
    from cogball.replay import ReplayWriter
    from cogball.server import results_document
    from cogball.sim import CogballSim

    require_sim_wasm()
    config = make_config(**config_overrides)
    seats = [StubSeat(0, "daveey", scripted=baselines[0]),
             StubSeat(1, "daveey-1", scripted=baselines[1])]
    first_kickoff_seat = config.seed & 1
    names = {
        "players": [p.name for p in config.players],
        "aliases": ["Azure", "Magenta"],
        "policy_kinds": [s.policy_kind for s in seats],
        "robots": [{"id": rid, "seat": i // 3, "hue": hue}
                   for i, (rid, hue) in enumerate(zip(
                       ("AZ-1", "AZ-2", "AZ-3", "MG-1", "MG-2", "MG-3"),
                       (190, 202, 214, 330, 342, 354)))],
    }
    writer = ReplayWriter(config, "unknown", first_kickoff_seat, names)
    sim = CogballSim(seed=config.seed, first_kickoff_seat=first_kickoff_seat)
    client = LlmClient()
    client.disabled = True
    client._resolved = True
    engine = TurnEngine(sim, config, seats, client, writer,
                        first_kickoff_seat=first_kickoff_seat)
    result = await engine.run()
    results_doc = results_document(config, result)
    return result, writer.finalize(results_doc), results_doc, engine
