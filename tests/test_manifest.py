"""The manifest template, the compose file and the policy set.

These are the files the ladder and the certifier read, and every assertion
here corresponds to a way a Coworld silently fails: no `num_agents` and the
ladder schedules zero episodes; a pod replay viewer and every hosted replay
hangs; URI-form docs and the coworld page is empty; one protocol instead of
two and the manifest is rejected.
"""

from __future__ import annotations

import json
import os
import re
import stat

from conftest import REPO_ROOT

from cogball import defaults

MANIFEST = json.loads(
    (REPO_ROOT / "coworld_manifest_template.json").read_text())
GAME = MANIFEST["game"]
IMAGE_NAME = "coworld-cogball"
SEATS = 2


def test_num_agents_is_declared_in_every_variant_and_the_fixture():
    assert MANIFEST["variants"], "no variants declared"
    for variant in MANIFEST["variants"]:
        config = variant["game_config"]
        assert config.get("num_agents") == SEATS, variant["id"]
        assert len(config["players"]) == SEATS, variant["id"]
    cert = MANIFEST["certification"]
    assert cert["game_config"]["num_agents"] == SEATS
    assert len(cert["players"]) == SEATS
    assert len(cert["game_config"]["players"]) == SEATS


def test_results_schema_matches_the_servers_closed_key_set():
    from cogball.config import GameConfig
    from cogball.engine import EpisodeResult
    from cogball.server import results_document

    config = GameConfig.from_dict({
        "players": [{"name": "a"}, {"name": "b"}],
        "tokens": ["t0", "t1"], "seed": 1})
    result = EpisodeResult(
        reason="complete", end_rule="full_time", winner=0,
        scores=(1.0, 0.0), win=(True, False), goals=(3, 0),
        final_tick=7200, final_turn=48, shots=(1, 1),
        shots_on_target=(1, 0), saves=(0, 1), passes_completed=(2, 0),
        interceptions=(0, 2), possession_ticks=(1, 1),
        distance_m=(0.0,) * defaults.NUM_ROBOTS, llm_turns=(48, 0),
        fallback_turns=(0, 48),
        fallback_causes=(dict.fromkeys(defaults.FALLBACK_CAUSES, 0),) * 2,
        policy_kinds=("llm", "scripted"))
    produced = set(results_document(config, result))
    schema = GAME["results_schema"]
    assert produced == set(schema["properties"]), (
        "results.json and the manifest results_schema disagree; they are a "
        "CLOSED schema and must be edited together")
    assert produced == set(schema["required"])
    assert schema["additionalProperties"] is False


def test_the_reason_and_end_rule_enums_are_the_closed_ones():
    props = GAME["results_schema"]["properties"]
    assert props["reason"]["enum"] == list(defaults.REASONS)
    assert props["end_rule"]["enum"] == list(defaults.END_RULES)
    causes = props["fallback_causes"]["items"]["properties"]
    assert set(causes) == set(defaults.FALLBACK_CAUSES)


def test_the_replay_viewer_is_the_static_bundle_never_a_pod():
    assert GAME["replay_viewer"] == {"bundle": "static-replay-viewer"}


def test_both_protocols_are_declared():
    protocols = GAME["protocols"]
    assert set(protocols) == {"player", "global"}
    for entry in protocols.values():
        assert entry["type"] == "uri"
        assert entry["value"].startswith(
            "https://github.com/Metta-AI/cogame-cogball/")


def test_docs_are_inline_text_and_track_the_files_they_came_from():
    docs = GAME["docs"]
    readme = docs["readme"]
    assert readme["type"] == "text"
    assert len(readme["value"]) > 1000
    assert readme["value"].splitlines()[0] == \
        (REPO_ROOT / "README.md").read_text().splitlines()[0]
    pages = docs["pages"]
    assert len(pages) == 2
    sources = {"protocol.md": REPO_ROOT / "docs" / "PROTOCOL.md",
               "coaching.md": REPO_ROOT / "docs" / "COACHING.md"}
    for page in pages:
        assert page["content"]["type"] == "text"
        assert len(page["content"]["value"]) > 1000
        assert page["title"]
        assert page["content"]["value"].splitlines()[0] == \
            sources[page["id"]].read_text().splitlines()[0], (
                f"{page['id']} has drifted from its source file; re-inline it")


def test_the_episode_budget_leaves_room_for_the_engine_to_settle():
    assert MANIFEST["episode_timeout_minutes"] == 20
    platform_seconds = MANIFEST["episode_timeout_minutes"] * 60
    for variant in MANIFEST["variants"]:
        budget = variant["game_config"]["wall_clock_budget_seconds"]
        assert budget <= 0.6 * platform_seconds, variant["id"]
    assert defaults.PLATFORM_EPISODE_TIMEOUT_MINUTES == \
        MANIFEST["episode_timeout_minutes"]
    assert defaults.DEFAULT_WALL_CLOCK_BUDGET_SECONDS == \
        MANIFEST["variants"][0]["game_config"]["wall_clock_budget_seconds"]


def test_the_certification_fixture_is_offline_and_quick():
    cert = MANIFEST["certification"]
    assert [p["player_id"] for p in cert["players"]] == ["baseline"] * SEATS
    baseline = next(p for p in MANIFEST["player"] if p["id"] == "baseline")
    assert baseline["env"] == {"PLAYER_SCRIPTED": "formation"}
    assert baseline["run"] == ["/bin/cogball-player"]
    assert "PLAYER_PROMPT" not in baseline.get("env", {})
    assert cert["game_config"]["max_ticks"] == 900


def test_the_game_entrypoint_and_source_url():
    assert GAME["name"] == "cogball"
    assert GAME["runnable"]["run"] == ["/bin/cogball"]
    assert GAME["runnable"]["image"] == "{{GAME_IMAGE}}"
    assert GAME["runnable"]["source_url"].endswith("cogame-cogball/tree/main")


def test_compose_uses_one_image_and_it_matches_the_scaffold():
    compose = (REPO_ROOT / "compose.yaml").read_text()
    images = re.findall(r"^\s+image:\s*(\S+)\s*$", compose, re.M)
    assert images == [f"{IMAGE_NAME}:latest"] * 2, images
    assert compose.count("platform: linux/amd64") == 2
    ci = (REPO_ROOT / ".github" / "workflows" / "ci.yml").read_text()
    assert f"IMAGE: {IMAGE_NAME}" in ci


def test_the_policy_set_is_two_prompts_two_baselines_one_image():
    policies = json.loads((REPO_ROOT / "tools" / "ci" / "policies.json").read_text())
    assert len(policies) == 4
    names = [p["name"] for p in policies]
    assert names == ["cogball-total", "cogball-counter",
                     "cogball-formation", "cogball-swarm"]
    for policy in policies:
        assert policy["run"] == "/bin/cogball-player"
        assert "image" not in policy      # one image, env-switched
    prompts = [p for p in policies if "PLAYER_PROMPT" in p["env"]]
    scripted = [p for p in policies if "PLAYER_SCRIPTED" in p["env"]]
    assert len(prompts) == 2 and len(scripted) == 2
    # the two champions must be genuinely different policies, or the second
    # upload dedupes onto the first version
    assert prompts[0]["env"]["PLAYER_PROMPT"] != prompts[1]["env"]["PLAYER_PROMPT"]
    assert "player" not in prompts[0]
    assert prompts[1]["player"] == "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    assert {p["env"]["PLAYER_SCRIPTED"] for p in scripted} == \
        set(defaults.BASELINES)


def test_the_ci_scaffold_has_no_unsubstituted_placeholders():
    files = [".github/workflows/ci.yml",
             ".github/workflows/coworld-release.yml",
             ".github/workflows/coworld-submit.yml",
             "tools/ci/docker_smoke.sh",
             "tools/ci/policies.json"]
    for name in files:
        text = (REPO_ROOT / name).read_text()
        for placeholder in ("<slug>", "<IMAGE>", "<SEATS>"):
            assert placeholder not in text, f"{name} still contains {placeholder}"


def test_the_ci_hooks_are_committed_executable():
    for name in ("tools/ci/docker_smoke.sh", "tools/build_replay_viewer.sh"):
        path = REPO_ROOT / name
        assert path.exists(), name
        assert os.stat(path).st_mode & stat.S_IXUSR, (
            f"{name} must be executable; fix with "
            f"git update-index --chmod=+x {name}")


def test_the_release_and_submit_workflows_expose_the_inputs_later_phases_pass():
    release = (REPO_ROOT / ".github" / "workflows" /
               "coworld-release.yml").read_text()
    for name in ("version:", "policies:", "put_secret:", "skip_certify:"):
        assert name in release
    assert "release-result" in release
    assert '"player"' in release      # per-policy owner for champion #2
    submit = (REPO_ROOT / ".github" / "workflows" /
              "coworld-submit.yml").read_text()
    for name in ("player_id:", "policy:", "league_id:"):
        assert name in submit
    assert "submit-result" in submit
