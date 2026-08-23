"""THE GATE.

cogball has no vendored upstream and therefore no fidelity gate; this test
replaces it as the inviolable one.  If it fails, the physics or a build flag
changed — fix the code, never the test.

Five layers:

a. same seed + same control bytes -> identical digests at every keyframe,
   twice in one instance and again in a fresh one;
b. a one-bit change to any control byte changes the outcome;
c. a committed golden fixture pins seed 42 over 3000 ticks, so a physics or
   control-layer change is visible in a diff;
d. **cross-build**: the same replay re-simulated by the emscripten build
   under node and by the standalone build under wasmtime yields equal
   digests at every 30-tick keyframe — the guarantee the whole replay design
   rests on;
e. a source guard: the physics core may use only ``+ - * / sqrt``, and
   neither build script may pass ``-ffast-math``.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess

import pytest
from conftest import (GOLDEN, HARNESS, REPO_ROOT, require_sim_wasm,
                      require_viewer_core)

from cogball import baselines, defaults
from cogball.control import World, compile_controls
from cogball.sim import CogballSim

SIM_DIR = REPO_ROOT / "sim"
CORE_FILES = ("cogball_core.c", "cogball_core.h", "cogball_config.h")

# Library calls whose results are NOT specified by WebAssembly: they are musl
# code, and emscripten's musl and the WASI SDK's musl are different builds.
# Anything in this list would make the cross-build guarantee depend on two
# toolchains agreeing about a transcendental.
BANNED_CALLS = re.compile(
    r"\b(sinf?|cosf?|tanf?|asinf?|acosf?|atanf?|atan2f?|expf?|logf?|log2f?"
    r"|log10f?|powf?|fmodf?|hypotf?)\s*\(")

C_COMMENTS = re.compile(r"/\*.*?\*/|//[^\n]*", re.S)


def code_of(path) -> str:
    """Source with comments removed.

    The ban is on what the compiler sees. Both files *document* the ban in
    prose ("no `float`", "only + - * / and sqrt"), and a grep that could not
    tell the two apart would have to be written around its own documentation.
    """
    return C_COMMENTS.sub(" ", path.read_text())


def run_match(seed: int, ticks: int):
    """Play a scripted match.

    Returns ``(keyframe digests, control log, live ticks)``. "Live" ticks are
    the ones outside a kickoff freeze, i.e. the ones whose control bytes the
    sim actually consumes.
    """
    require_sim_wasm()
    sim = CogballSim(seed=seed, first_kickoff_seat=0)
    digests, log, live = [], bytearray(), []
    for tick in range(ticks):
        world = World.from_state(sim.state())
        if tick % 30 == 0:
            digests.append((tick, sim.state_digest()))
        if sim.frozen():
            ctl = bytes(18)
        else:
            ctl = compile_controls(
                world,
                [baselines.formation(world, 0), baselines.swarm(world, 1)])
            live.append(tick)
        log += ctl
        sim.set_controls(ctl)
        sim.step()
    return digests, bytes(log), live


def replay_log(seed: int, log: bytes):
    """Feed a recorded control log back in and resample the digests."""
    sim = CogballSim(seed=seed, first_kickoff_seat=0)
    digests = []
    for tick in range(len(log) // 18):
        if tick % 30 == 0:
            digests.append((tick, sim.state_digest()))
        sim.set_controls(log[tick * 18:(tick + 1) * 18])
        sim.step()
    return digests, sim.state_digest()


# -- (a) reproducibility ------------------------------------------------------

@pytest.mark.slow
def test_same_seed_and_controls_reproduce_every_keyframe():
    digests, log, _live = run_match(42, 7200)
    again, final_a = replay_log(42, log)
    assert again == digests
    # a genuinely fresh instance (new Store, new memory), same answer
    fresh, final_b = replay_log(42, log)
    assert fresh == digests
    assert final_a == final_b
    assert len(digests) == 240


def test_a_one_bit_control_change_changes_the_outcome():
    base_digests, log, live = run_match(42, 600)
    baseline_final = replay_log(42, log)[1]
    # Sample thrust bytes on live ticks, spread across the log. (A kick byte
    # on a tick where the ball is out of reach, or any byte during a kickoff
    # freeze, is genuinely inert -- the sim never reads it.)
    sampled = [live[i] * 18 + robot * 3
               for i, robot in zip(range(0, len(live), max(1, len(live) // 8)),
                                   (0, 1, 2, 3, 4, 5, 0, 1, 2))]
    assert len(sampled) >= 5
    for offset in sampled:
        mutated = bytearray(log)
        mutated[offset] ^= 0x01
        digests, final = replay_log(42, bytes(mutated))
        assert (digests, final) != (base_digests, baseline_final), \
            f"flipping bit 0 of control byte {offset} changed nothing"


# -- (c) the golden fixture ---------------------------------------------------

def test_golden_digests_still_hold():
    require_sim_wasm()
    golden = json.loads(GOLDEN.read_text())
    digests, log, _live = run_match(golden["seed"], golden["ticks"])
    import hashlib
    assert hashlib.sha256(log).hexdigest() == golden["controls_sha256"], (
        "the control layer produced different bytes than the golden fixture; "
        "if that was intended, regenerate tests/data/golden_digests.json and "
        "say so in the commit message")
    assert [list(d) for d in digests] == golden["keyframes"], (
        "the physics diverged from the golden fixture; if that was intended, "
        "regenerate tests/data/golden_digests.json and say so in the commit "
        "message")
    assert replay_log(golden["seed"], log)[1] == golden["final_digest"]


# -- (d) cross-build ----------------------------------------------------------

@pytest.mark.slow
async def test_emscripten_and_wasmtime_agree_at_every_keyframe(tmp_path):
    """The whole replay design rests on this."""
    from conftest import record_scripted_episode

    core = require_viewer_core()
    node = shutil.which("node")
    if node is None:
        pytest.skip("node not on PATH")

    _result, replay_bytes, _doc, _engine = await record_scripted_episode(
        max_ticks=1200)
    path = tmp_path / "replay.json"
    path.write_bytes(replay_bytes)

    proc = subprocess.run([node, str(HARNESS), str(core), str(path)],
                          capture_output=True, text=True, timeout=600)
    assert proc.returncode == 0, f"harness failed:\n{proc.stderr}"
    out = json.loads(proc.stdout)

    document = json.loads(replay_bytes.decode("utf-8"))
    recorded = [[k["t"], k["d"]] for k in document["keyframes"]]
    assert out["total"] == document["tick_count"]
    assert out["digests"] == recorded, (
        "the emscripten build and the wasmtime build disagree about the "
        "physics; the replay would not re-simulate in a browser")


# -- (e) the source guard -----------------------------------------------------

def test_the_physics_core_uses_only_plus_minus_times_divide_and_sqrt():
    for name in CORE_FILES:
        text = code_of(SIM_DIR / name)
        hit = BANNED_CALLS.search(text)
        assert hit is None, (
            f"sim/{name} calls {hit.group(1)}(): libm results are NOT "
            "specified by WebAssembly, so the emscripten and standalone "
            "builds would be free to disagree")
        assert not re.search(r"\bfloat\b", text), (
            f"sim/{name} uses `float`: single-precision accumulation order "
            "changes with optimisation level")


def test_no_libm_calls_anywhere_in_the_sim_sources():
    for path in sorted(SIM_DIR.glob("*.c")) + sorted(SIM_DIR.glob("*.h")):
        hit = BANNED_CALLS.search(code_of(path))
        assert hit is None, f"{path.name} calls {hit.group(1)}()"


def test_build_scripts_never_pass_fast_math():
    for name in ("build_sim.sh", "build_viewer.sh"):
        text = (SIM_DIR / name).read_text()
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith("#"):
                continue  # the ban is documented in a comment in both files
            assert "-ffast-math" not in stripped, \
                f"sim/{name} passes -ffast-math"


def test_the_control_layer_output_is_quantised_before_the_sim():
    """The determinism boundary: the sim only ever sees bytes."""
    require_sim_wasm()
    sim = CogballSim(seed=3, first_kickoff_seat=1)
    world = World.from_state(sim.state())
    ctl = compile_controls(
        world, [baselines.formation(world, 0), baselines.swarm(world, 1)])
    assert isinstance(ctl, bytes)
    assert len(ctl) == defaults.NUM_ROBOTS * 3
    for i in range(defaults.NUM_ROBOTS):
        thrust = int.from_bytes(ctl[i * 3:i * 3 + 1], "big", signed=True)
        turn = int.from_bytes(ctl[i * 3 + 1:i * 3 + 2], "big", signed=True)
        assert -100 <= thrust <= 100
        assert -100 <= turn <= 100
        assert ctl[i * 3 + 2] in (0, 1)
