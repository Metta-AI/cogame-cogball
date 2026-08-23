"""aiohttp game server implementing the Coworld runtime contract.

Episode mode (default): read the game config from ``COGAME_CONFIG_URI``,
serve ``GET /player?slot=N&token=T`` websockets, run one 3v3 match, then
write ``results.json`` to ``COGAME_RESULTS_URI`` and the replay JSON to
``COGAME_SAVE_REPLAY_URI`` and exit 0.  Seats that never connect are
declared to ``COGAME_PLAYER_FAILURE_URI`` and played by the `formation`
baseline — a no-show never ends the episode.

Wire protocol (docs/PROTOCOL.md is the authority).  A player sends exactly
one frame on connect and then only receives::

    player -> server  {"type":"register","prompt":"…","scripted":null,
                       "policy":"…"}
    server -> player  {"type":"turn","turn":7,"tick":1050,"view":{…},
                       "directive_source":"llm"}          (every 150 ticks)
    server -> player  {"done":true,"result":{…}}          (episode end)

Decisions are made server-side (see server/cogball/llm.py): the hosted
Bedrock credential and the ``anthropic_api_key`` Coworld secret are injected
into the *game* pod, so the coach lives here and the player container is
thin.

Global viewer: ``GET /global`` is a broadcast-only websocket (status
snapshot, throttled progress, final result).  Browser pages live at
``GET /client/global`` and ``GET /client/player``.

Replay mode: with ``COGAME_LOAD_REPLAY_URI`` set no episode runs; the
recorded replay is served at ``GET /replay-data`` and the static wasm viewer
at ``GET /client/replay``.

Entry point: ``python -m cogball.server`` (``/bin/cogball`` in the image).
"""

from __future__ import annotations

import asyncio
import hmac
import json
import os
import sys
from pathlib import Path

from aiohttp import WSCloseCode, WSMsgType, web

from . import defaults, uris
from .config import ConfigError, GameConfig
from .directives import truncate_runes
from .engine import EpisodeResult, TurnEngine
from .llm import LlmClient
from .replay import PROTOCOL, Replay, ReplayError, ReplayWriter, sim_core_sha256
from .sim import DEFAULT_WASM_PATH, CogballSim

SHUTDOWN_GRACE_SECONDS = 1.0
GLOBAL_TICK_EVERY = 150
PLAYER_WS_HEARTBEAT_SECONDS = 20.0

GLOBAL_CLIENT_HTML = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>cogball</title>
<style>
  body { font-family: ui-monospace, monospace; margin: 2rem; }
  #log { white-space: pre-wrap; }
</style>
</head>
<body>
<h1>cogball live feed</h1>
<div id="log">connecting to /global ...</div>
<script>
const log = document.getElementById("log");
const proto = location.protocol === "https:" ? "wss:" : "ws:";
const ws = new WebSocket(proto + "//" + location.host + "/global");
ws.onmessage = (ev) => { log.textContent += "\\n" + ev.data; };
ws.onopen = () => { log.textContent = "connected"; };
ws.onclose = () => { log.textContent += "\\n[closed]"; };
</script>
</body>
</html>
"""

PLAYER_CLIENT_HTML = """<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>cogball seat</title></head>
<body style="font-family: ui-monospace, monospace; margin: 2rem;">
<h1>cogball</h1>
<p>Seat <span id="slot"></span> is played over the websocket protocol
(<code>GET /player?slot=N&amp;token=T</code>, see docs/PROTOCOL.md);
this page only confirms the seat credential is valid.</p>
<script>
document.getElementById("slot").textContent =
  new URLSearchParams(location.search).get("slot");
</script>
</body>
</html>
"""


def results_document(config: GameConfig, result: EpisodeResult) -> dict:
    """results.json — a CLOSED schema.

    Adding or removing a key here means editing
    ``coworld_manifest_template.json``'s ``results_schema`` and
    ``tools/ci/docker_smoke.sh``'s expectations in the same commit.
    """
    return {
        "names": [p.name for p in config.players],
        "aliases": list(defaults.ALIASES),
        "policy_kinds": list(result.policy_kinds),
        "scores": list(result.scores),
        "win": list(result.win),
        "goals": list(result.goals),
        "reason": result.reason,
        "end_rule": result.end_rule,
        "winner": result.winner,
        "final_tick": result.final_tick,
        "final_turn": result.final_turn,
        "seed": config.seed,
        "shots": list(result.shots),
        "shots_on_target": list(result.shots_on_target),
        "saves": list(result.saves),
        "passes_completed": list(result.passes_completed),
        "interceptions": list(result.interceptions),
        "possession_ticks": list(result.possession_ticks),
        "distance_m": list(result.distance_m),
        "llm_turns": list(result.llm_turns),
        "fallback_turns": list(result.fallback_turns),
        "fallback_causes": [dict(c) for c in result.fallback_causes],
    }


def fault_results_document(config: GameConfig, policy_kinds: list[str],
                           final_tick: int) -> dict:
    """A schema-complete doc for an episode the host lost outright."""
    return {
        "names": [p.name for p in config.players],
        "aliases": list(defaults.ALIASES),
        "policy_kinds": list(policy_kinds),
        "scores": [0.5, 0.5],
        "win": [False, False],
        "goals": [0, 0],
        "reason": "fault",
        "end_rule": "host_error",
        "winner": None,
        "final_tick": final_tick,
        "final_turn": 0,
        "seed": config.seed,
        "shots": [0, 0],
        "shots_on_target": [0, 0],
        "saves": [0, 0],
        "passes_completed": [0, 0],
        "interceptions": [0, 0],
        "possession_ticks": [0, 0],
        "distance_m": [0.0] * defaults.NUM_ROBOTS,
        "llm_turns": [0, 0],
        "fallback_turns": [0, 0],
        "fallback_causes": [dict.fromkeys(defaults.FALLBACK_CAUSES, 0)
                            for _ in range(config.num_seats)],
    }


class WsSeat:
    """One player seat: websocket state plus the seat's declared policy.

    The seat is informational during play — the coach runs server-side — so
    ``push`` is best-effort and bounded and can never stall a tick.
    """

    def __init__(self, slot: int, name: str):
        self.slot = slot
        self.name = name
        self.alias = defaults.ALIASES[slot]
        self.ws: web.WebSocketResponse | None = None
        self.ever_connected = False
        self.registered = False
        self.prompt = ""
        self.scripted: str | None = None
        self.policy_label = ""

    @property
    def connected(self) -> bool:
        return self.ws is not None and not self.ws.closed

    @property
    def policy_kind(self) -> str:
        return "llm" if self.prompt else "scripted"

    def register(self, data: dict) -> None:
        """Apply one ``register`` frame. Anything illegal degrades quietly."""
        prompt = data.get("prompt")
        if isinstance(prompt, str) and prompt.strip():
            # Over-long prompts are truncated at the transport, not rejected.
            self.prompt = truncate_runes(prompt.strip(),
                                         defaults.PROMPT_MAX_RUNES)
        scripted = data.get("scripted")
        if isinstance(scripted, str) and scripted in defaults.BASELINES:
            self.scripted = scripted
        label = data.get("policy")
        if isinstance(label, str):
            self.policy_label = truncate_runes(
                label, defaults.POLICY_LABEL_MAX_RUNES)
        if not self.prompt and self.scripted is None:
            self.scripted = defaults.DEFAULT_BASELINE
        self.registered = True
        print(f"seat {self.slot} ({self.name}) registered as "
              f"{self.policy_kind}"
              f"{'/' + self.scripted if self.scripted else ''}"
              f" label={self.policy_label!r}", file=sys.stderr)

    async def push(self, payload: dict) -> None:
        ws = self.ws
        if ws is None or ws.closed:
            return
        try:
            await asyncio.wait_for(
                ws.send_str(json.dumps(payload, ensure_ascii=False)),
                defaults.DONE_SEND_TIMEOUT_SECONDS)
        except Exception:
            pass  # a seat that stopped reading must never stall the match


class GameServer:
    def __init__(self, config: GameConfig, *,
                 results_uri: str | None = None,
                 save_replay_uri: str | None = None,
                 player_failure_uri: str | None = None,
                 sim_factory=CogballSim,
                 llm_client=None,
                 wasm_path=DEFAULT_WASM_PATH):
        self.config = config
        self.results_uri = results_uri
        self.save_replay_uri = save_replay_uri
        self.player_failure_uri = player_failure_uri
        self.sim_factory = sim_factory
        self.wasm_path = wasm_path
        self.llm = llm_client if llm_client is not None else LlmClient()
        self.seats = [WsSeat(slot, player.name)
                      for slot, player in enumerate(config.players)]
        self._all_connected = asyncio.Event()
        self.result: EpisodeResult | None = None
        self.results_doc: dict | None = None
        self._global_wss: set[web.WebSocketResponse] = set()
        self._global_send_tasks: dict[web.WebSocketResponse, asyncio.Task] = {}
        self._last_tick = 0
        # The seat that restarts play at the opening kickoff, derived from
        # the seed so it is reproducible from the replay alone.
        self.first_kickoff_seat = config.seed & 1

    # -- routes ------------------------------------------------------------

    def make_app(self) -> web.Application:
        app = web.Application()
        app.router.add_get("/healthz", self._handle_healthz)
        app.router.add_get("/player", self._handle_player)
        app.router.add_get("/global", self._handle_global)
        app.router.add_get("/client/global", self._handle_global_client)
        app.router.add_get("/client/player", self._handle_player_client)
        return app

    async def _handle_healthz(self, request: web.Request) -> web.Response:
        return web.json_response({"status": "ok"})

    def _authorized_slot(self, request: web.Request) -> int:
        try:
            slot = int(request.query.get("slot", ""))
        except ValueError:
            raise web.HTTPForbidden(text="bad slot")
        if not 0 <= slot < len(self.seats):
            raise web.HTTPForbidden(text="bad slot")
        token = request.query.get("token", "")
        if not hmac.compare_digest(token.encode("utf-8"),
                                   self.config.tokens[slot].encode("utf-8")):
            raise web.HTTPForbidden(text="bad token")
        return slot

    async def _handle_global_client(self, request: web.Request) -> web.Response:
        return web.Response(text=GLOBAL_CLIENT_HTML, content_type="text/html")

    async def _handle_player_client(self, request: web.Request) -> web.Response:
        self._authorized_slot(request)
        return web.Response(text=PLAYER_CLIENT_HTML, content_type="text/html")

    async def _handle_global(self, request: web.Request):
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        snapshot = {
            "type": "status",
            "players": [s.name for s in self.seats],
            "aliases": list(defaults.ALIASES),
            "max_ticks": self.config.max_ticks,
            "turn_ticks": self.config.turn_ticks,
            "done": self.results_doc is not None,
        }
        if self.results_doc is not None:
            snapshot["result"] = self.results_doc
        await ws.send_str(json.dumps(snapshot))
        self._global_wss.add(ws)
        try:
            async for _msg in ws:
                pass  # broadcast-only
        finally:
            self._global_wss.discard(ws)
            self._global_send_tasks.pop(ws, None)
        return ws

    def _broadcast_global(self, payload: dict) -> None:
        if not self._global_wss:
            return
        message = json.dumps(payload)
        loop = asyncio.get_running_loop()
        for ws in tuple(self._global_wss):
            if ws.closed:
                continue
            prev = self._global_send_tasks.get(ws)
            if prev is not None and not prev.done():
                continue  # per-socket serialization: drop, never interleave
            task = loop.create_task(self._global_send(ws, message))
            self._global_send_tasks[ws] = task
            task.add_done_callback(
                lambda t, ws=ws: self._discard_global_send(ws, t))

    def _discard_global_send(self, ws, task) -> None:
        if self._global_send_tasks.get(ws) is task:
            del self._global_send_tasks[ws]

    @staticmethod
    async def _global_send(ws: web.WebSocketResponse, message: str) -> None:
        try:
            await ws.send_str(message)
        except Exception:
            pass  # viewer sockets can never affect the episode

    async def _handle_player(self, request: web.Request):
        slot = self._authorized_slot(request)
        seat = self.seats[slot]
        if seat.connected:
            print(f"seat {slot} ({seat.name}): rejected duplicate connection "
                  f"(409) at tick {self._last_tick}", file=sys.stderr)
            raise web.HTTPConflict(text="slot already connected")

        ws = web.WebSocketResponse(heartbeat=PLAYER_WS_HEARTBEAT_SECONDS)
        await ws.prepare(request)
        if seat.connected:  # TOCTOU: a concurrent connect won during prepare
            await ws.close(code=WSCloseCode.POLICY_VIOLATION,
                           message=b"slot already connected")
            return ws
        seat.ws = ws
        seat.ever_connected = True
        print(f"seat {slot} ({seat.name}) connected at tick "
              f"{self._last_tick}", file=sys.stderr)
        if all(s.connected for s in self.seats):
            self._all_connected.set()

        try:
            async for msg in ws:
                if msg.type != WSMsgType.TEXT:
                    continue
                try:
                    data = json.loads(msg.data)
                except json.JSONDecodeError:
                    continue  # malformed: never crash the episode
                if isinstance(data, dict) and data.get("type") == "register":
                    seat.register(data)
        finally:
            if seat.ws is ws:
                seat.ws = None
                print(f"seat {slot} ({seat.name}) disconnected at tick "
                      f"{self._last_tick}", file=sys.stderr)
        return ws

    # -- episode orchestration --------------------------------------------

    async def run_episode(self) -> EpisodeResult:
        cfg = self.config
        try:
            await asyncio.wait_for(self._all_connected.wait(),
                                   cfg.player_connect_timeout_seconds)
        except (asyncio.TimeoutError, TimeoutError):
            pass
        # Give a connected seat a moment to send its register frame before
        # turn 0 is decided; bounded, and a seat that never registers simply
        # plays `formation`.
        for _ in range(20):
            if all(s.registered for s in self.seats if s.connected):
                break
            await asyncio.sleep(0.05)

        no_shows = [s for s in self.seats if not s.ever_connected]
        for seat in no_shows:
            seat.scripted = defaults.DEFAULT_BASELINE
            print(f"seat {seat.slot} ({seat.name}) never connected; playing "
                  f"the {defaults.DEFAULT_BASELINE} baseline", file=sys.stderr)
        if no_shows:
            # The failure URI holds a single doc: report the LOWEST slot.
            await self._report_player_failure(no_shows[0])

        writer = ReplayWriter(cfg, self._wasm_sha256(),
                              self.first_kickoff_seat, self._names_doc())

        def on_tick(tick: int) -> None:
            self._last_tick = tick
            if tick % GLOBAL_TICK_EVERY == 0:
                self._broadcast_global({"tick": tick})

        try:
            sim = self.sim_factory(seed=cfg.seed,
                                   first_kickoff_seat=self.first_kickoff_seat)
            engine = TurnEngine(sim, cfg, self.seats, self.llm, writer,
                                on_tick=on_tick,
                                first_kickoff_seat=self.first_kickoff_seat)
            result = await engine.run()
        except Exception as exc:
            # The engine contains sim faults itself; reaching here is an
            # unexpected host failure. Artifacts are the episode's whole
            # point: write fault results + the partial replay, then re-raise.
            print(f"unexpected engine failure: {type(exc).__name__}: {exc}; "
                  f"writing fault artifacts", file=sys.stderr)
            await self._write_fault_artifacts(writer)
            raise
        finally:
            await self.llm.close()

        self.result = result
        results_doc = self._results_doc(result)
        self.results_doc = results_doc
        print(f"episode over: reason={result.reason} "
              f"end_rule={result.end_rule} score={result.goals[0]}-"
              f"{result.goals[1]} tick={result.final_tick} "
              f"llm_turns={list(result.llm_turns)} "
              f"fallback_turns={list(result.fallback_turns)}",
              file=sys.stderr)

        write_errors: list[str] = []

        async def attempt(label: str, uri: str | None, data: bytes,
                          content_type: str) -> None:
            if not uri:
                return
            try:
                await uris.write_uri(uri, data, content_type)
            except Exception as exc:
                write_errors.append(f"{label} -> {uri}: {exc}")

        # Done broadcast FIRST: artifact writes retry with backoff and
        # connected players must not wait that out to learn the match ended.
        await self._broadcast_done(results_doc)
        await attempt(
            "results", self.results_uri,
            (json.dumps(results_doc, ensure_ascii=False, indent=2)
             + "\n").encode("utf-8"), "application/json")
        await attempt("replay", self.save_replay_uri,
                      writer.finalize(results_doc), "application/json")
        if write_errors:
            raise IOError("artifact writes failed: " + "; ".join(write_errors))
        return result

    def _names_doc(self) -> dict:
        return {
            "players": [p.name for p in self.config.players],
            "aliases": list(defaults.ALIASES),
            "policy_kinds": [s.policy_kind for s in self.seats],
            "robots": [
                {"id": defaults.ROBOT_IDS[i],
                 "seat": defaults.seat_of_robot(i),
                 "hue": defaults.ROBOT_HUES[i]}
                for i in range(defaults.NUM_ROBOTS)],
        }

    def _wasm_sha256(self) -> str:
        try:
            return sim_core_sha256(self.wasm_path)
        except OSError as exc:
            print(f"sim wasm sha256 unavailable ({exc}); the replay will "
                  f"record \"unknown\"", file=sys.stderr)
            return "unknown"

    def _results_doc(self, result: EpisodeResult) -> dict:
        return results_document(self.config, result)

    def _fault_results_doc(self, final_tick: int) -> dict:
        return fault_results_document(
            self.config, [s.policy_kind for s in self.seats], final_tick)

    async def _write_fault_artifacts(self, writer: ReplayWriter) -> None:
        """Best-effort fault results + partial replay (never raises)."""
        results_doc = self._fault_results_doc(writer.tick_count)
        self.results_doc = results_doc
        for label, uri, data, ctype in (
                ("results", self.results_uri,
                 (json.dumps(results_doc, ensure_ascii=False, indent=2)
                  + "\n").encode("utf-8"), "application/json"),
                ("replay", self.save_replay_uri,
                 writer.finalize(results_doc), "application/json")):
            if not uri:
                continue
            try:
                await uris.write_uri(uri, data, ctype)
            except Exception as exc:
                print(f"fault-artifact write failed: {label} -> {uri}: {exc}",
                      file=sys.stderr)
        try:
            await self._broadcast_done(results_doc)
        except Exception as exc:
            print(f"fault done-broadcast failed: {exc}", file=sys.stderr)

    async def _report_player_failure(self, seat: WsSeat) -> None:
        if not self.player_failure_uri:
            return
        payload = {
            "message": (
                f"player '{seat.name}' in slot {seat.slot} did not connect "
                f"within {self.config.player_connect_timeout_seconds:g}s "
                f"(reason: connect_timeout); the seat plays the "
                f"{defaults.DEFAULT_BASELINE} baseline"),
            "failed_policy_index": seat.slot,
        }
        try:
            await uris.write_uri(self.player_failure_uri,
                                 json.dumps(payload).encode("utf-8"),
                                 "application/json")
        except Exception as exc:  # best-effort: never blocks the episode
            print(f"player-failure report failed: {exc}", file=sys.stderr)

    async def _broadcast_done(self, results_doc: dict) -> None:
        message = json.dumps({"done": True, "result": results_doc},
                             ensure_ascii=False)

        async def _send(ws: web.WebSocketResponse) -> None:
            await ws.send_str(message)
            await ws.close()

        async def send_and_close(seat: WsSeat) -> None:
            ws = seat.ws
            if ws is None or ws.closed:
                return
            try:
                await asyncio.wait_for(
                    _send(ws), defaults.DONE_SEND_TIMEOUT_SECONDS)
            except Exception:
                pass

        async def send_and_close_global(ws: web.WebSocketResponse) -> None:
            prev = self._global_send_tasks.get(ws)
            if prev is not None and not prev.done():
                try:
                    await asyncio.wait_for(
                        asyncio.shield(prev),
                        defaults.DONE_SEND_TIMEOUT_SECONDS)
                except Exception:
                    pass
            try:
                await asyncio.wait_for(
                    _send(ws), defaults.DONE_SEND_TIMEOUT_SECONDS)
            except Exception:
                pass

        await asyncio.gather(
            *(send_and_close(s) for s in self.seats),
            *(send_and_close_global(ws) for ws in tuple(self._global_wss)
              if not ws.closed),
            return_exceptions=True)


# -- replay mode -------------------------------------------------------------

DEFAULT_VIEWER_DIST = Path(__file__).resolve().parents[2] / "viewer" / "dist"

REPLAY_PLACEHOLDER_HTML = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>cogball replay</title>
<style>
  body { font-family: ui-monospace, monospace; margin: 2rem; }
  dt { font-weight: bold; margin-top: .6rem; }
  .note { margin-top: 2rem; color: #666; }
</style>
</head>
<body>
<h1>cogball replay</h1>
<dl id="info">loading /replay-data ...</dl>
<p class="note">Placeholder viewer: this server was built without the wasm
re-simulation bundle (run sim/build_viewer.sh).</p>
<script>
async function load() {
  const resp = await fetch("/replay-data");
  const doc = await resp.json();
  const info = document.getElementById("info");
  info.textContent = "";  // textContent: names are player data
  const add = (label, value) => {
    const dt = document.createElement("dt");
    dt.textContent = label;
    const dd = document.createElement("dd");
    dd.textContent = String(value);
    info.appendChild(dt); info.appendChild(dd);
  };
  add("protocol", doc.protocol);
  add("players", doc.names.players.join(" vs "));
  add("score", doc.results.goals.join(" - "));
  add("reason", doc.results.reason + " / " + doc.results.end_rule);
  add("ticks", doc.tick_count);
}
load().catch(e => {
  document.getElementById("info").textContent = "failed: " + e.message;
});
</script>
</body>
</html>
"""


def make_replay_app(replay_bytes: bytes,
                    viewer_dist: Path | None = None) -> web.Application:
    """Replay-mode app: raw JSON at /replay-data, viewer at /client/replay.

    Raises ReplayError on corrupt bytes (fail at startup, not per request).
    """
    replay = Replay.parse(replay_bytes)
    dist = DEFAULT_VIEWER_DIST if viewer_dist is None else Path(viewer_dist)
    index = dist / "index.html"
    have_bundle = index.is_file()
    if not have_bundle:
        print(f"viewer bundle not found at {dist}; serving the placeholder "
              f"page (run sim/build_viewer.sh)", file=sys.stderr)

    async def handle_replay_data(request: web.Request) -> web.Response:
        return web.Response(body=replay_bytes, content_type="application/json")

    async def handle_replay_client(request: web.Request):
        if have_bundle:
            # index references its assets relatively; redirect to the slash
            # form so they resolve under /client/replay/.
            raise web.HTTPFound("/client/replay/")
        return web.Response(text=REPLAY_PLACEHOLDER_HTML,
                            content_type="text/html")

    async def handle_replay_index(request: web.Request):
        if have_bundle:
            return web.FileResponse(index)
        return web.Response(text=REPLAY_PLACEHOLDER_HTML,
                            content_type="text/html")

    async def handle_healthz(request: web.Request) -> web.Response:
        return web.json_response({"status": "ok"})

    async def handle_replay_ws(request: web.Request):
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        await ws.send_str(json.dumps({
            "type": "replay_header",
            "protocol": replay.doc["protocol"],
            "tick_count": replay.tick_count,
            "results": replay.doc["results"],
        }))
        async for _msg in ws:
            pass
        return ws

    app = web.Application()
    app.router.add_get("/healthz", handle_healthz)
    app.router.add_get("/replay", handle_replay_ws)
    app.router.add_get("/replay-data", handle_replay_data)
    app.router.add_get("/client/replay", handle_replay_client)
    app.router.add_get("/client/replay/", handle_replay_index)
    if have_bundle:
        app.router.add_static("/client/replay/", dist)
    return app


# -- process entry point -----------------------------------------------------

async def async_main() -> int:
    host = os.environ.get("COGAME_HOST", "0.0.0.0")
    port = int(os.environ.get("COGAME_PORT", "8080"))

    load_replay_uri = os.environ.get("COGAME_LOAD_REPLAY_URI", "")
    if load_replay_uri:
        replay_bytes = await uris.read_uri(load_replay_uri)
        try:
            app = make_replay_app(replay_bytes)
        except ReplayError as exc:
            print(f"invalid replay at {load_replay_uri}: {exc}",
                  file=sys.stderr)
            return 2
        runner = web.AppRunner(app)
        await runner.setup()
        await web.TCPSite(runner, host, port).start()
        print(f"cogball replay mode on {host}:{port} "
              f"({len(replay_bytes)} bytes, {PROTOCOL})", file=sys.stderr)
        await asyncio.Event().wait()
        return 0

    config_uri = os.environ.get("COGAME_CONFIG_URI", "")
    if not config_uri:
        print("COGAME_CONFIG_URI is required", file=sys.stderr)
        return 2
    try:
        if uris.local_path(config_uri) is not None:
            config = GameConfig.from_file_uri(config_uri)
        else:
            raw = await uris.read_uri(config_uri)
            try:
                data = json.loads(raw)
            except json.JSONDecodeError as exc:
                raise ConfigError(
                    f"config at {config_uri} is not valid JSON: {exc}") from exc
            config = GameConfig.from_dict(data)
    except ConfigError as exc:
        print(f"invalid config: {exc}", file=sys.stderr)
        return 2
    except (OSError, ValueError) as exc:
        print(f"cannot read config from {config_uri}: {exc}", file=sys.stderr)
        return 2

    server = GameServer(
        config,
        results_uri=os.environ.get("COGAME_RESULTS_URI"),
        save_replay_uri=os.environ.get("COGAME_SAVE_REPLAY_URI"),
        player_failure_uri=os.environ.get("COGAME_PLAYER_FAILURE_URI"),
    )
    runner = web.AppRunner(server.make_app())
    await runner.setup()
    await web.TCPSite(runner, host, port).start()
    print(f"cogball serving on {host}:{port} ({config.num_seats} seats x "
          f"{defaults.ROBOTS_PER_SEAT} robots, {config.max_ticks} ticks)",
          file=sys.stderr)
    await server.run_episode()
    await asyncio.sleep(SHUTDOWN_GRACE_SECONDS)
    await runner.cleanup()
    return 0


def main() -> int:
    return asyncio.run(async_main())


if __name__ == "__main__":
    sys.exit(main())
