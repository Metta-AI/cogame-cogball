"""wasmtime host for the cogball physics core compiled to wasm.

The module is a WASI reactor (emscripten ``-sSTANDALONE_WASM --no-entry``)
built by ``sim/build_sim.sh`` from ``sim/cogball_core.c`` — the *same* C the
browser viewer is built from, which is what makes a replay re-simulate
bit-identically in the viewer.  See ``sim/cogball_core.h`` for the exports.
"""

from __future__ import annotations

import struct
from pathlib import Path

from wasmtime import (Config, Engine, Func, FuncType, Linker, Module, Store,
                      ValType, WasiConfig)

from . import defaults

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_WASM_PATH = REPO_ROOT / "build" / "cogball_sim.wasm"

STATE_FIELDS = 60
CTL_BYTES = defaults.NUM_ROBOTS * 3

# Physics event type codes, mirroring sim/cogball_config.h CB_EV_*.
EV_KICK = 1
EV_TOUCH = 2
EV_POST = 3
EV_GOAL = 4
EV_KICKOFF = 5

# Engine/Module compilation is cached per wasm path: one CogballSim is
# constructed per episode (and hundreds per test session), and recompiling
# the module every time dominates the runtime otherwise.
_MODULE_CACHE: dict[str, tuple[Engine, Module]] = {}


def _load_module(wasm_path: Path) -> tuple[Engine, Module]:
    key = str(wasm_path)
    if key not in _MODULE_CACHE:
        engine = Engine(Config())
        _MODULE_CACHE[key] = (engine, Module.from_file(engine, key))
    return _MODULE_CACHE[key]


class SimFault(RuntimeError):
    """The wasm sim trapped or tripped an invariant guard."""


class CogballSim:
    """One cogball episode hosted in wasm.

    ``seed`` is a 32-bit unsigned value (wider ints are masked);
    ``first_kickoff_seat`` is the seat that restarts play at kickoff.
    """

    def __init__(self, seed: int = 1, first_kickoff_seat: int = 0,
                 wasm_path: str | Path = DEFAULT_WASM_PATH):
        wasm_path = Path(wasm_path)
        if not wasm_path.exists():
            raise FileNotFoundError(
                f"{wasm_path} not found - run sim/build_sim.sh first")

        engine, module = _load_module(wasm_path)
        self._store = Store(engine)
        wasi = WasiConfig()
        wasi.inherit_stdout()
        wasi.inherit_stderr()
        self._store.set_wasi(wasi)

        linker = Linker(engine)
        linker.define_wasi()
        # -sALLOW_MEMORY_GROWTH emits this notification import; no-op stub.
        linker.define(
            self._store, "env", "emscripten_notify_memory_growth",
            Func(self._store, FuncType([ValType.i32()], []),
                 lambda _idx: None))
        instance = linker.instantiate(self._store, module)
        self._exports = instance.exports(self._store)
        self._memory = self._exports["memory"]

        # WASI reactor: emscripten static constructors run here. A
        # freestanding build (no libc) exports no _initialize.
        init = self._exports.get("_initialize")
        if init is not None:
            init(self._store)

        seed = seed & 0xFFFFFFFF
        self._exports["cogball_init"](
            self._store, _as_i32(seed), int(first_kickoff_seat) & 1)

        self._ctl_ptr = self._exports["cogball_ctl_ptr"](self._store)
        self._state_ptr = self._exports["cogball_state_ptr"](self._store)
        self._event_ptr = self._exports["cogball_event_ptr"](self._store)
        self._event_stride = self._exports["cogball_event_stride"](self._store)
        self._state_struct = struct.Struct("<%dd" % STATE_FIELDS)

    # -- lockstep API ------------------------------------------------------

    def set_controls(self, ctl: bytes) -> None:
        """Write the tick's 18 quantised control bytes.

        Layout: ``NUM_ROBOTS x (int8 thrust, int8 turn, uint8 kick)`` in
        robot-index order.  These bytes are the determinism boundary — the
        sim never sees an un-quantised control and the replay stores exactly
        this.
        """
        if len(ctl) != CTL_BYTES:
            raise ValueError(
                f"controls must be {CTL_BYTES} bytes, got {len(ctl)}")
        self._memory.write(self._store, ctl, self._ctl_ptr)

    def step(self) -> None:
        self._exports["cogball_step"](self._store)

    def state(self) -> tuple[float, ...]:
        """Packed world state; layout in sim/cogball_config.h."""
        raw = self._memory.read(
            self._store, self._state_ptr,
            self._state_ptr + STATE_FIELDS * 8)
        return self._state_struct.unpack(bytes(raw))

    def events(self) -> list[tuple[float, ...]]:
        """Physics events emitted by the last step (the ring is per-tick)."""
        count = self._exports["cogball_event_count"](self._store)
        if count <= 0:
            return []
        stride = self._event_stride
        raw = bytes(self._memory.read(
            self._store, self._event_ptr,
            self._event_ptr + count * stride * 8))
        out = []
        for i in range(count):
            out.append(struct.unpack_from("<%dd" % stride, raw, i * stride * 8))
        return out

    def tick(self) -> int:
        return self._exports["cogball_tick"](self._store)

    def goals(self, seat: int) -> int:
        return self._exports["cogball_goals"](self._store, seat)

    def frozen(self) -> bool:
        """True during the 1.0 s kickoff freeze after a goal."""
        return bool(self._exports["cogball_frozen"](self._store))

    def fault(self) -> bool:
        return bool(self._exports["cogball_fault"](self._store))

    def debug_place_ball(self, x: float, y: float,
                         vx: float, vy: float) -> None:
        """Test-only: put the ball somewhere specific (tests/test_physics.py).

        Never called by the engine or the viewer, so a replay is still fully
        reproduced by the seed plus the action log.
        """
        self._exports["cogball_debug_place_ball"](self._store, x, y, vx, vy)

    def debug_place_robot(self, index: int, x: float, y: float,
                          hx: float = 1.0, hy: float = 0.0,
                          vx: float = 0.0, vy: float = 0.0) -> None:
        """Test-only: put one robot somewhere specific."""
        self._exports["cogball_debug_place_robot"](
            self._store, index, x, y, hx, hy, vx, vy)

    def state_digest(self) -> int:
        """u32 FNV-1a over the full dynamic state + score + tick.

        The browser viewer's ``viewer_state_digest()`` must return exactly
        this at the same tick; tests/test_determinism.py is the gate.
        """
        return self._exports["cogball_state_digest"](self._store) & 0xFFFFFFFF


def _as_i32(value: int) -> int:
    """Re-encode a u32 as the signed i32 bit pattern the wasm ABI wants."""
    return value - (1 << 32) if value >= (1 << 31) else value
