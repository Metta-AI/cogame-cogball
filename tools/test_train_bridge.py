"""Exercise both certified Cogball variants through the numeric protocol."""

import json
import random
import subprocess
import sys
from pathlib import Path


BINARY = Path(sys.argv[1]).resolve()
MANIFEST = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"


def process_for(variant: str) -> subprocess.Popen[str]:
    return subprocess.Popen(
        [str(BINARY), str(MANIFEST), variant], stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, text=True, bufsize=1, cwd="/tmp",
    )


def request(process: subprocess.Popen[str], payload: dict) -> dict:
    assert process.stdin is not None and process.stdout is not None
    process.stdin.write(json.dumps(payload) + "\n")
    process.stdin.flush()
    return json.loads(process.stdout.readline())


def play(variant: str, teacher: bool) -> None:
    process = process_for(variant)
    rng = random.Random(29)
    try:
        observation = request(process, {"kind": "reset", "seed": f"cogball-{variant}-{teacher}", "players": 2})
        widths = set()
        decisions = 0
        while observation["kind"] == "decision":
            assert observation["game"] == "cogball"
            assert observation["seat"] == decisions % 2
            assert observation["decision_id"] == decisions
            view = observation["semantic_view"]
            assert "seed" not in view
            assert json.loads(observation["messages"][1]["content"]) == view
            encoding = request(process, {"kind": "encode"})
            assert encoding["decision_id"] == decisions
            widths.add(len(encoding["values"]))
            assert len(encoding["actions"]) == 345
            if teacher:
                choice = json.loads(request(process, {"kind": "teacher"})["response"])
            else:
                choice = rng.choice(encoding["actions"])
            result = request(process, {"kind": "step", "decision_id": decisions,
                                       "response": json.dumps(choice)})
            assert result["kind"] == "accepted" and result["action"] == choice
            observation = result["observation"]
            decisions += 1
            assert decisions <= (80 if variant == "default" else 40)
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == set(observation["utilities"]) == {"0", "1"}
        assert sum(observation["scores"].values()) == 1000
        assert abs(sum(observation["utilities"].values())) < 1e-9
        assert len(widths) == 1 and decisions > 0
        print(variant, "teacher" if teacher else "random", widths.pop(), decisions,
              observation["scores"])
    finally:
        assert process.stdin is not None and process.stdout is not None
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


def check_frozen_views() -> None:
    views = []
    for choice in (0, 2):
        process = process_for("default")
        try:
            request(process, {"kind": "reset", "seed": "cogball-frozen", "players": 2})
            result = request(process, {"kind": "step", "decision_id": 0,
                                       "response": json.dumps({"choice": choice})})
            views.append(result["observation"]["semantic_view"])
        finally:
            assert process.stdin is not None and process.stdout is not None
            process.stdin.close()
            process.stdout.close()
            assert process.wait(timeout=5) == 0
    assert views[0] == views[1]


if __name__ == "__main__":
    check_frozen_views()
    for name in ("default", "sprint"):
        for use_teacher in (True, False):
            play(name, use_teacher)
