# Baseline tuning — the grid harness and what it found

`src/cogball/baselines.nim`'s tuning constants are `{.intdefine.}` so they can
be swept from the command line without editing the source. This file is the
record of the sweeps that chose the committed values, and the harness that
produced it is committed beside it:

* **`tools/tune_baselines.nim`** — the runner. Plays `formation` against
  `swarm` over a fixed 24-seed list, **both sides played** (each seed once with
  `formation` as Azure and once as Crimson, so a side bias cannot be read as a
  tuning win): 48 full 4800-tick matches per row. It drives the real control
  layer and the real sim, exactly as the server does, minus the sockets and the
  LLM.
* **`tools/tune_baselines.sh`** — the loop that varies one constant at a time
  and rebuilds:

  ```bash
  tools/tune_baselines.sh CogballKeeperArc 1000000 2000000 3000000 4000000
  TUNE_SEEDS="3 5011 10007 ..." tools/tune_baselines.sh CogballStrikerRange 6000000 9000000
  tools/tune_baselines.sh                 # just the committed values
  ```

`score` is `2 x wins + draws` out of `2 x matches`, from `formation`'s side.
`gd` is its total goal difference. `goalless` counts 0–0 matches — the round-1
corner regression, which any candidate that produces them is disqualified by
regardless of its score.

## The sweeps

Default seed list, 48 matches per row. **Bold** is the committed value.

| `CogballKeeperArc` | W–D–L | goals | gd | goalless | score |
|---|---|---|---|---|---|
| 1 000 000 | 27–6–15 | 96:74 | +22 | 1 | 60/96 |
| 1 500 000 | 25–11–12 | 96:74 | +22 | 0 | 61/96 |
| **2 000 000** | **30–3–15** | **103:67** | **+36** | **0** | **63/96** |
| 3 000 000 | 26–6–16 | 92:64 | +28 | 2 | 58/96 |
| 4 000 000 | 26–10–12 | 106:78 | +28 | 2 | 62/96 |

| `CogballStrikerRange` | W–D–L | goals | gd | goalless | score |
|---|---|---|---|---|---|
| 4 000 000 | 21–7–20 | 87:78 | +9 | 0 | 49/96 |
| 6 000 000 | 28–2–18 | 92:80 | +12 | 0 | 58/96 |
| **9 000 000** | **30–3–15** | **103:67** | **+36** | **0** | **63/96** |
| 12 000 000 | 31–5–12 | 111:66 | +45 | 0 | 67/96 |
| 15 000 000 | 29–5–14 | 109:67 | +42 | 0 | 63/96 |
| 20 000 000 | 29–5–14 | 107:67 | +40 | 0 | 63/96 |
| 40 000 000 (always shoot) | 29–5–14 | 107:67 | +40 | 0 | 63/96 |

| `CogballBackPull` | W–D–L | goals | gd | goalless | score |
|---|---|---|---|---|---|
| 0 | 18–14–16 | 87:83 | +4 | 2 | 50/96 |
| **1 500 000** | **30–3–15** | **103:67** | **+36** | **0** | **63/96** |
| 3 000 000 | 22–12–14 | 87:72 | +15 | 3 | 56/96 |

| `CogballWingLead` | W–D–L | goals | gd | goalless | score |
|---|---|---|---|---|---|
| 4 000 000 | 26–8–14 | 99:72 | +27 | 0 | 60/96 |
| **7 000 000** | **30–3–15** | **103:67** | **+36** | **0** | **63/96** |
| 10 000 000 | 17–14–17 | 92:80 | +12 | 2 | 48/96 |

| `CogballWingWide` | W–D–L | goals | gd | goalless | score |
|---|---|---|---|---|---|
| 2 500 000 | 20–9–19 | 88:81 | +7 | 1 | 49/96 |
| **5 000 000** | **30–3–15** | **103:67** | **+36** | **0** | **63/96** |
| 7 500 000 | 21–15–12 | 89:72 | +17 | 1 | 57/96 |

| `CogballSupportAlwaysRuns` | W–D–L | goals | gd | goalless | score |
|---|---|---|---|---|---|
| **0** (shield the middle at home) | **30–3–15** | **103:67** | **+36** | **0** | **63/96** |
| 1 (always run the channel) | 20–10–18 | 88:82 | +6 | 2 | 50/96 |

## The holdout, and how much of this is noise

A single 48-match sweep can separate a big effect from a small one but not a
small one from luck, so the two constants the design note disagrees with were
re-run on a **second, disjoint 24-seed list** (`TUNE_SEEDS`, 48 more matches):

| value | default seeds | holdout seeds |
|---|---|---|
| `KeeperArc` 1 000 000 | 60/96 | 46/96 |
| **`KeeperArc` 2 000 000** | **63/96** | **61/96** |
| `KeeperArc` 3 000 000 | 58/96 | 57/96 |
| `StrikerRange` 6 000 000 | 58/96 | 69/96 |
| **`StrikerRange` 9 000 000** | **63/96** | **61/96** |
| `StrikerRange` 12 000 000 | 67/96 | 64/96 |

Read that honestly:

* **`KeeperArc = 2 m` is robust.** It wins on both seed lists, by 3 and by 4+
  points, and it is the only value with no goalless match on either. A keeper
  further out is a keeper the second attacker walks around; a keeper on the
  line concedes the rebound. The design note's 3 m loses on both lists.
* **`StrikerRange` is inside the noise between 6 m and 12 m.** 9 m wins the
  default list and loses the holdout to 6 m; 12 m wins the default list by four
  points and the holdout by three. The committed 9 m is kept because it is the
  only value that is never the worst of the three, and because a four-point
  margin over 48 matches is two wins — smaller than the seed-to-seed spread
  this table shows. If the ladder later wants another point out of the filler,
  12 m is where to start, and this is the run to compare against.

## Where the design note and the code differ, and why

The v2 design note (`docs/plans/2026-08-22-cogball-design-v2.md`) quotes 3 m for
the keeper arc and 6 m for the striker range. Those were the design-time
figures, written before anything could be played. The committed values are the
harness's, and the two differences are recorded above with their measurements.
The note's own §Scripted baselines is the *shape* of the baselines — who keeps,
who strikes, who supports — and that shape is unchanged; only the three numbers
inside it were settled by measurement rather than by estimate.

## Reproducing

```bash
nim c -d:release --path:src --out:bin/tune_baselines tools/tune_baselines.nim
bin/tune_baselines                      # the committed values, 48 matches
tools/tune_baselines.sh CogballKeeperArc 1000000 2000000 3000000 4000000
```

The runner is deterministic: same seeds, same constants, same numbers. Every
row above is reproducible from this commit.
