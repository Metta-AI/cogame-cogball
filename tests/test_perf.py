"""Performance: the physics must be a rounding error in the wall-clock budget.

The 690 s engine stop is sized for LLM latency, not for the sim. A full
7 200-tick match is ~29 000 substeps of six circle-circle bodies; it should
take a second or two under wasmtime. The bound here is deliberately generous
(20 s) so it catches an order-of-magnitude regression, not runner noise.
"""

from __future__ import annotations

import time

import pytest
from conftest import require_sim_wasm

from cogball import baselines
from cogball.control import World, compile_controls
from cogball.sim import CogballSim


@pytest.mark.slow
def test_a_full_match_of_physics_is_fast_under_wasmtime():
    require_sim_wasm()
    sim = CogballSim(seed=42, first_kickoff_seat=0)
    world = World.from_state(sim.state())
    directives = [baselines.formation(world, 0), baselines.swarm(world, 1)]
    ctl = compile_controls(world, directives)
    started = time.monotonic()
    for _ in range(7200):
        sim.set_controls(ctl)
        sim.step()
    elapsed = time.monotonic() - started
    assert elapsed < 20.0, f"7200 ticks took {elapsed:.1f}s"
    print(f"7200 ticks in {elapsed:.2f}s "
          f"({7200 / max(elapsed, 1e-9):.0f} ticks/s)")


@pytest.mark.slow
def test_a_full_match_with_the_control_layer_in_the_loop_is_fast():
    """The whole per-tick server path, not just the wasm call."""
    require_sim_wasm()
    sim = CogballSim(seed=7, first_kickoff_seat=1)
    started = time.monotonic()
    directives = None
    for tick in range(7200):
        world = World.from_state(sim.state())
        if tick % 150 == 0:
            directives = [baselines.formation(world, 0),
                          baselines.swarm(world, 1)]
        sim.set_controls(bytes(18) if sim.frozen()
                         else compile_controls(world, directives))
        sim.step()
        sim.events()
    elapsed = time.monotonic() - started
    assert elapsed < 30.0, f"7200 full ticks took {elapsed:.1f}s"
