#!/usr/bin/env python3
"""Gate the freshly recorded wasm-smoke fixture before the bundle consumes it.

A fixture that did not actually record an episode would make the native/wasm
determinism gate pass vacuously, which is worse than a red run: it is a green
signal derived from nothing.
"""
import json
import sys

summary = json.load(open(sys.argv[1], encoding="utf-8"))
checks = [
    ("protocol", summary.get("protocol") == "cogball/v1"),
    ("gameVersion present", bool(summary.get("gameVersion"))),
    ("seed pinned to 679961", summary.get("seed") == 679961),
    ("num_agents is 2", summary.get("numAgents") == 2),
    ("more than 1000 ticks", (summary.get("tickCount") or 0) > 1000),
    ("input records present", (summary.get("inputRecords") or 0) > 100),
    ("both seats registered",
     all(summary.get("policyKinds") or [None, None])),
    ("at least 18 directives", len(summary.get("directives") or []) >= 18),
    ("results written", isinstance(summary.get("results"), dict)),
    ("episode completed",
     (summary.get("results") or {}).get("reason") == "complete"),
]
failed = [name for name, ok in checks if not ok]
for name, ok in checks:
    print(("  ok   " if ok else "  FAIL ") + name)
if failed:
    print("::error::fixture is not a usable recording: " + ", ".join(failed))
    sys.exit(1)
print("fixture ok: %d ticks, hash chain %s"
      % (summary["tickCount"], summary["hashChain"]))
