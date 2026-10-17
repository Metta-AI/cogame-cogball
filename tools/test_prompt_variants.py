"""Complete ordinary matches preserve coach views and directives across wording."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

BINARY = str(Path(sys.argv[1]).resolve())
MANIFEST = str(Path(__file__).resolve().parents[1] / "coworld_manifest_template.json")
VARIANTS = [
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
]


def request(process, command):
    process.stdin.write(json.dumps(command) + "\n")
    process.stdin.flush()
    line = process.stdout.readline()
    assert line, process.poll()
    return json.loads(line)


completed = 0
for game, decisions in (("default", 80), ("sprint", 40)):
    with subprocess.Popen(
        [BINARY, MANIFEST, game, "--language"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as process:
        for seed in ("17", "946001"):
            baseline = None
            direct = []
            for choice, prompt_seed in [(v, 0) for v in VARIANTS] + [
                ("mixed", i) for i in range(5)
            ]:
                obs = request(
                    process,
                    {
                        "kind": "reset",
                        "seed": seed,
                        "players": 2,
                        "promptVariant": choice,
                        "promptSeed": prompt_seed,
                        "split": "validation" if seed == "17" else "test",
                    },
                )
                trace, systems = [], set()
                while obs["kind"] == "decision":
                    view = obs["semantic_view"]
                    meta = view.pop("prompt_template")
                    selected = VARIANTS[prompt_seed] if choice == "mixed" else choice
                    messages = obs["messages"]
                    assert (
                        meta["bank"],
                        meta["variant"],
                        meta["selection"],
                        meta["seed"],
                    ) == ("cogball-rules-v1", selected, choice, prompt_seed)
                    for message in messages:
                        assert (
                            meta[message["role"] + "_sha256"]
                            == hashlib.sha256(message["content"].encode()).hexdigest()
                        )
                    systems.add(messages[0]["content"])
                    assert (
                        json.loads(messages[1]["content"].split("\n\n", 1)[1]) == view
                    )
                    assert "prompt_template" not in messages[1]["content"]
                    assert len(view["your_robots"]) == len(view["their_robots"]) == 3
                    assert "seed" not in view
                    seat = obs["seat"]
                    assert f"PRIVATE-{1 - seat}" not in messages[1]["content"]
                    action = json.loads(
                        request(process, {"kind": "teacher"})["response"]
                    )
                    action["note"] = f"PRIVATE-{seat}"
                    response = request(
                        process,
                        {
                            "kind": "step",
                            "decision_id": obs["decision_id"],
                            "response": json.dumps(action),
                        },
                    )
                    assert response["kind"] == "accepted"
                    assert response["action"]["note"] == action["note"]
                    trace.append((view, messages[1], response["action"]))
                    obs = response["observation"]
                    assert len(trace) <= decisions
                assert (
                    obs["kind"] == "terminal"
                    and len(trace) == decisions
                    and len(systems) == 1
                )
                result = trace, obs
                if choice == "canonical":
                    baseline = result
                else:
                    assert result == baseline
                system = systems.pop()
                if choice == "mixed":
                    assert system == direct[prompt_seed]
                else:
                    assert system not in direct
                    direct.append(system)
                completed += 1
            print(game, seed, "12 complete wording games PASS", flush=True)
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0

for language in (False, True):
    invalids = [
        {"promptVariant": v}
        for v in ("heldout-briefing", "heldout-reference", "unknown", "mixed")
    ]
    invalids += [{"split": "unknown"}]
    invalids += [
        {"promptVariant": "mixed", "promptSeed": seed} for seed in (-1, True, 1.5)
    ]
    if not language:
        invalids.append({"promptVariant": "plain"})
    for invalid in invalids:
        result = subprocess.run(
            [BINARY, MANIFEST, "default"] + (["--language"] if language else []),
            input=json.dumps({"kind": "reset", "seed": "17", "players": 2} | invalid)
            + "\n",
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode != 0 and not result.stdout

comparisons = 0
if len(sys.argv) == 3:
    for game in ("default", "sprint"):
        processes = [
            subprocess.Popen(
                [str(Path(binary).resolve()), MANIFEST, game],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            for binary in (sys.argv[2], BINARY)
        ]
        try:
            for seed in ("17", "946001"):
                observations = [
                    request(p, {"kind": "reset", "seed": seed, "players": 2})
                    for p in processes
                ]
                while observations[0]["kind"] == "decision":
                    assert observations[0] == observations[1]
                    encodings = [request(p, {"kind": "encode"}) for p in processes]
                    assert (
                        encodings[0] == encodings[1]
                        and len(encodings[0]["actions"]) == 345
                    )
                    actions = [
                        request(p, {"kind": "teacher"})["response"] for p in processes
                    ]
                    assert actions[0] == actions[1]
                    results = [
                        request(
                            p,
                            {
                                "kind": "step",
                                "decision_id": obs["decision_id"],
                                "response": action,
                            },
                        )
                        for p, obs, action in zip(
                            processes, observations, actions, strict=True
                        )
                    ]
                    assert results[0] == results[1]
                    observations = [r["observation"] for r in results]
                assert observations[0] == observations[1]
                comparisons += 1
        finally:
            for process in processes:
                process.stdin.close()
                process.stdout.close()
                assert process.wait(timeout=5) == 0
print(
    json.dumps(
        {
            "complete_language_games": completed,
            "original_numeric_comparisons": comparisons,
        }
    )
)
