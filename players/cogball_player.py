"""The cogball player container: register once, then watch.

Decisions are made by the game server (server/cogball/llm.py), so a player
is deliberately thin.  On connect it sends exactly one frame::

    {"type":"register","prompt":"<strategy text or empty>",
     "scripted":"formation"|"swarm"|null,"policy":"<label, <=48 runes>"}

and then only receives — one ``{"type":"turn",…}`` frame per decision turn
and finally ``{"done":true,"result":{…}}``.

Environment:
  COWORLD_PLAYER_WS_URL / COGAMES_ENGINE_WS_URL   the seat websocket
  PLAYER_PROMPT      strategy text -> this seat is an LLM seat
  PLAYER_SCRIPTED    formation | swarm -> this seat is a scripted seat
  PLAYER_POLICY_LABEL  free label recorded in the game log

A seat that sets neither PLAYER_PROMPT nor PLAYER_SCRIPTED plays
``formation``.

Entry point: ``python -m players.cogball_player`` (``/bin/cogball-player``).
"""

from __future__ import annotations

import asyncio
import json
import os
import sys

import aiohttp
from aiohttp import WSMsgType

WS_URL_ENV_VARS = ("COWORLD_PLAYER_WS_URL", "COGAMES_ENGINE_WS_URL")
BASELINES = ("formation", "swarm")

MAX_CONNECT_ATTEMPTS = 5
RECONNECT_DELAY_SECONDS = 0.5
# Bound on establishing one websocket connection: a black-holed connect must
# fail fast instead of eating the whole reconnect budget.
CONNECT_TIMEOUT_SECONDS = 20.0

# 403 can never succeed on retry. 409 (slot already connected) usually means
# our own stale connection has not been reaped yet, so it IS retried.
_FATAL_HTTP_STATUSES = {403: "connection rejected (403): bad slot or token"}


class PlayerError(Exception):
    """Fatal player-side failure (bad env, bad auth, server gone)."""


def ws_url_from_env() -> str:
    for name in WS_URL_ENV_VARS:
        url = os.environ.get(name)
        if url:
            return url
    raise PlayerError("no websocket URL: set " + " or ".join(WS_URL_ENV_VARS))


def register_frame() -> dict:
    """The one frame this container sends, built from the environment."""
    prompt = (os.environ.get("PLAYER_PROMPT") or "").strip()
    scripted = (os.environ.get("PLAYER_SCRIPTED") or "").strip().lower()
    if scripted and scripted not in BASELINES:
        print(f"player: unknown PLAYER_SCRIPTED={scripted!r}; using "
              f"'formation'", file=sys.stderr)
        scripted = "formation"
    if not prompt and not scripted:
        scripted = "formation"
    label = (os.environ.get("PLAYER_POLICY_LABEL") or "").strip()
    if not label:
        label = "prompt" if prompt else scripted
    return {
        "type": "register",
        "prompt": prompt,
        "scripted": scripted or None,
        "policy": label,
    }


async def play_episode(url: str | None = None) -> dict:
    """Register, then receive until the done message. Returns the result."""
    if url is None:
        url = ws_url_from_env()
    frame = register_frame()
    kind = "prompt" if frame["prompt"] else f"scripted/{frame['scripted']}"
    print(f"player: connecting as {kind} (label={frame['policy']!r})",
          file=sys.stderr)

    failures = 0
    turns_seen = 0
    timeout = aiohttp.ClientTimeout(total=None,
                                    connect=CONNECT_TIMEOUT_SECONDS,
                                    sock_connect=CONNECT_TIMEOUT_SECONDS)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        while True:
            try:
                ws = await session.ws_connect(url)
            except aiohttp.WSServerHandshakeError as exc:
                if exc.status in _FATAL_HTTP_STATUSES:
                    raise PlayerError(
                        _FATAL_HTTP_STATUSES[exc.status]) from exc
                failures += 1
                if failures >= MAX_CONNECT_ATTEMPTS:
                    raise PlayerError(
                        f"giving up after {failures} failed connection "
                        f"attempts (last status {exc.status})") from exc
                await asyncio.sleep(RECONNECT_DELAY_SECONDS)
                continue
            except (aiohttp.ClientError, OSError) as exc:
                failures += 1
                if failures >= MAX_CONNECT_ATTEMPTS:
                    raise PlayerError(
                        f"giving up after {failures} failed connection "
                        f"attempts: {exc}") from exc
                await asyncio.sleep(RECONNECT_DELAY_SECONDS)
                continue

            try:
                result, seen = await _watch(ws, frame)
            finally:
                try:
                    await ws.close()
                except Exception:
                    pass  # a close failure must never fail a done episode
            turns_seen += seen
            if result is not None:
                print(f"player: episode done after {turns_seen} turns",
                      file=sys.stderr)
                return result
            if seen > 0:
                failures = 0  # made progress: fresh reconnect budget
            failures += 1
            if failures >= MAX_CONNECT_ATTEMPTS:
                raise PlayerError(
                    "connection closed before the done message "
                    f"({failures} consecutive times)")
            await asyncio.sleep(RECONNECT_DELAY_SECONDS)


async def _watch(ws, frame: dict) -> tuple[dict | None, int]:
    seen = 0
    try:
        await ws.send_str(json.dumps(frame, ensure_ascii=False))
        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                continue
            try:
                data = json.loads(msg.data)
            except json.JSONDecodeError:
                continue
            if not isinstance(data, dict):
                continue
            if data.get("done"):
                return data.get("result", {}), seen
            if data.get("type") == "turn":
                seen += 1
    except (aiohttp.ClientError, ConnectionError):
        pass  # dropped mid-episode: the caller decides whether to reconnect
    return None, seen


def main() -> int:
    try:
        result = asyncio.run(play_episode())
    except PlayerError as exc:
        print(f"player failed: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    print(f"episode done: result={json.dumps(result)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
