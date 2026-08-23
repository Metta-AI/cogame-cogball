"""The websocket contract, the artifact writes and replay mode."""

from __future__ import annotations

import asyncio
import json

import aiohttp
import pytest
from aiohttp import web
from conftest import make_config, record_scripted_episode, require_sim_wasm

from cogball import defaults
from cogball.llm import LlmClient
from cogball.server import GameServer, make_replay_app


def disabled_client() -> LlmClient:
    client = LlmClient()
    client.disabled = True
    client._resolved = True
    return client


async def serve(app) -> tuple[web.AppRunner, str]:
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    return runner, f"http://127.0.0.1:{port}"


def game_server(tmp_path, **config_overrides) -> GameServer:
    require_sim_wasm()
    config = make_config(**config_overrides)
    return GameServer(
        config,
        results_uri=f"file://{tmp_path}/results.json",
        save_replay_uri=f"file://{tmp_path}/replay.json",
        player_failure_uri=f"file://{tmp_path}/player_failure.json",
        llm_client=disabled_client())


async def register(session, base: str, slot: int, **frame):
    ws = await session.ws_connect(
        f"{base}/player?slot={slot}&token=token-{slot}")
    payload = {"type": "register", "prompt": "", "scripted": "formation",
               "policy": f"seat-{slot}"}
    payload.update(frame)
    await ws.send_str(json.dumps(payload))
    return ws


async def test_healthz_and_the_client_pages():
    server = game_server_stub()
    runner, base = await serve(server.make_app())
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(f"{base}/healthz") as resp:
                assert resp.status == 200
                assert (await resp.json()) == {"status": "ok"}
            async with session.get(f"{base}/client/global") as resp:
                assert resp.status == 200
                assert "text/html" in resp.headers["content-type"]
            async with session.get(
                    f"{base}/client/player?slot=0&token=token-0") as resp:
                assert resp.status == 200
            async with session.get(
                    f"{base}/client/player?slot=0&token=nope") as resp:
                assert resp.status == 403
    finally:
        await runner.cleanup()


def game_server_stub() -> GameServer:
    require_sim_wasm()
    return GameServer(make_config(), llm_client=disabled_client())


async def test_a_bad_token_or_slot_is_403_and_a_duplicate_is_409():
    server = game_server_stub()
    runner, base = await serve(server.make_app())
    try:
        async with aiohttp.ClientSession() as session:
            with pytest.raises(aiohttp.WSServerHandshakeError) as exc:
                await session.ws_connect(f"{base}/player?slot=0&token=wrong")
            assert exc.value.status == 403
            with pytest.raises(aiohttp.WSServerHandshakeError) as exc:
                await session.ws_connect(f"{base}/player?slot=9&token=token-0")
            assert exc.value.status == 403

            ws = await register(session, base, 0)
            await asyncio.sleep(0.1)
            with pytest.raises(aiohttp.WSServerHandshakeError) as exc:
                await session.ws_connect(
                    f"{base}/player?slot=0&token=token-0")
            assert exc.value.status == 409
            await ws.close()
    finally:
        await runner.cleanup()


async def test_a_register_frame_sets_the_seats_policy_kind():
    server = game_server_stub()
    runner, base = await serve(server.make_app())
    try:
        async with aiohttp.ClientSession() as session:
            ws0 = await register(session, base, 0, prompt="press high",
                                 scripted=None, policy="total")
            ws1 = await register(session, base, 1, scripted="swarm")
            await asyncio.sleep(0.2)
            assert server.seats[0].policy_kind == "llm"
            assert server.seats[0].prompt == "press high"
            assert server.seats[0].policy_label == "total"
            assert server.seats[1].policy_kind == "scripted"
            assert server.seats[1].scripted == "swarm"
            await ws0.close()
            await ws1.close()
    finally:
        await runner.cleanup()


async def test_an_over_long_prompt_is_truncated_on_rune_boundaries():
    server = game_server_stub()
    runner, base = await serve(server.make_app())
    try:
        async with aiohttp.ClientSession() as session:
            long_prompt = "\U0001F3C6" * 5000
            ws = await register(session, base, 0, prompt=long_prompt,
                                scripted=None)
            await asyncio.sleep(0.2)
            assert len(server.seats[0].prompt) == defaults.PROMPT_MAX_RUNES
            server.seats[0].prompt.encode("utf-8").decode("utf-8")
            await ws.close()
    finally:
        await runner.cleanup()


async def test_a_full_episode_writes_the_artifacts_and_broadcasts_done(
        tmp_path):
    server = game_server(tmp_path, max_ticks=300,
                         player_connect_timeout_seconds=3)
    runner, base = await serve(server.make_app())
    try:
        async with aiohttp.ClientSession() as session:
            ws0 = await register(session, base, 0)
            ws1 = await register(session, base, 1, scripted="swarm")
            global_ws = await session.ws_connect(f"{base}/global")
            snapshot = json.loads(await global_ws.receive_str())
            assert snapshot["type"] == "status"
            assert snapshot["players"] == ["daveey", "daveey-1"]

            result = await server.run_episode()
            assert result.reason == "complete"

            turns, done = 0, None
            while True:
                message = json.loads(await ws0.receive_str())
                if message.get("done"):
                    done = message
                    break
                turns += 1
            assert turns == 2
            assert done["result"]["reason"] == "complete"
            await ws1.close()
            await global_ws.close()

        results = json.loads((tmp_path / "results.json").read_bytes()
                             .decode("utf-8"))
        assert results["names"] == ["daveey", "daveey-1"]
        assert len(results["scores"]) == 2
        assert results["scores"][0] + results["scores"][1] == 1.0
        assert results["policy_kinds"] == ["scripted", "scripted"]
        replay = json.loads((tmp_path / "replay.json").read_bytes()
                            .decode("utf-8"))
        assert replay["protocol"] == "cogball/v1"
        assert replay["tick_count"] == 300
        assert not (tmp_path / "player_failure.json").exists()
    finally:
        await runner.cleanup()


async def test_a_no_show_seat_is_reported_and_plays_the_baseline(tmp_path):
    server = game_server(tmp_path, max_ticks=150,
                         player_connect_timeout_seconds=0.3)
    runner, base = await serve(server.make_app())
    try:
        async with aiohttp.ClientSession() as session:
            ws0 = await register(session, base, 0)
            result = await server.run_episode()
            await ws0.close()
        assert result.reason == "complete"     # a no-show never ends the match
        failure = json.loads((tmp_path / "player_failure.json").read_text())
        assert failure["failed_policy_index"] == 1
        assert "did not connect" in failure["message"]
        assert server.seats[1].scripted == defaults.DEFAULT_BASELINE
    finally:
        await runner.cleanup()


async def test_malformed_frames_never_crash_the_episode(tmp_path):
    server = game_server(tmp_path, max_ticks=150,
                         player_connect_timeout_seconds=1)
    runner, base = await serve(server.make_app())
    try:
        async with aiohttp.ClientSession() as session:
            ws0 = await session.ws_connect(
                f"{base}/player?slot=0&token=token-0")
            await ws0.send_str("not json at all")
            await ws0.send_str(json.dumps([1, 2, 3]))
            await ws0.send_str(json.dumps({"type": "shout", "at": "ref"}))
            ws1 = await register(session, base, 1)
            result = await server.run_episode()
            await ws0.close()
            await ws1.close()
        assert result.reason == "complete"
        # a seat that never registered plays the default baseline
        assert server.seats[0].policy_kind == "scripted"
    finally:
        await runner.cleanup()


async def test_replay_mode_serves_the_recorded_bytes(tmp_path):
    _result, data, _doc, _engine = await record_scripted_episode(max_ticks=150)
    app = make_replay_app(data, viewer_dist=tmp_path / "no-bundle-here")
    runner, base = await serve(app)
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(f"{base}/replay-data") as resp:
                assert resp.status == 200
                document = json.loads((await resp.read()).decode("utf-8"))
                assert document["protocol"] == "cogball/v1"
            async with session.get(f"{base}/client/replay") as resp:
                assert resp.status == 200
                assert "cogball replay" in (await resp.text())
            async with session.get(f"{base}/healthz") as resp:
                assert resp.status == 200
            ws = await session.ws_connect(f"{base}/replay")
            header = json.loads(await ws.receive_str())
            assert header["type"] == "replay_header"
            assert header["protocol"] == "cogball/v1"
            await ws.close()
    finally:
        await runner.cleanup()


async def test_replay_mode_serves_the_static_bundle_when_it_is_present(
        tmp_path):
    _result, data, _doc, _engine = await record_scripted_episode(max_ticks=150)
    dist = tmp_path / "dist"
    dist.mkdir()
    (dist / "index.html").write_text("<html>cogball bundle</html>")
    app = make_replay_app(data, viewer_dist=dist)
    runner, base = await serve(app)
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(f"{base}/client/replay/") as resp:
                assert resp.status == 200
                assert "cogball bundle" in (await resp.text())
    finally:
        await runner.cleanup()
