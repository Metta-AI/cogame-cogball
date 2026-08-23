# Where the code diverges from the accepted design note

The accepted note is [`2026-08-22-cogball-design-v2.md`](2026-08-22-cogball-design-v2.md).
It is frozen: it is the record of what was agreed, and it is not edited after
the fact. This file is the other half of that discipline — every place the
shipped code does something the note describes differently, what it does
instead, and why. A divergence that is not listed here is a bug.

Nothing here changes the note's *shape*. These are places where building the
thing settled a detail the note had estimated, or where the note's wording was
ambiguous and the code had to pick.

---

## Pass and interception attribution comes from state, not from `intent`

**Note** (§Shots, saves, passes): "A kick made **under intent `pass`** whose
next touch is a different robot of the same seat within 96 ticks is a completed
pass".

**Code** (`src/cogball/sim.nim`, `applyKicks` / `recordTouch`): every kick that
lands arms the pass window, regardless of the directive's intent. The next
different toucher inside 96 ticks scores a completed pass (same seat) or an
interception (opponent).

**Why.** The counters are inside `gameHash` (`sim_state.nim`), and directives
are outside the determinism boundary by construction — the recorded action log
is the six input masks, and the wasm viewer re-simulates from those alone. It
never sees a directive, so anything the viewer must reproduce cannot depend on
one. Reading `intent` in `sim.nim` would make the hash chain depend on state
the viewer does not have, which is the one failure mode the whole replay design
exists to prevent. AGENTS.md states the rule ("the sim can never read a
directive"); `docs/RULES.md` §Shots, saves, passes states the resulting rule
for players.

The cost is small and in the honest direction: a kick that *was* a pass in
everything but the declared label still counts as one, and a hopeful punt that
happens to find a team-mate also does. Neither can be gamed — the counters are
reporting, not scoring; `results.scores` is goals only.

---

## The realised goal mouth is narrower than the 7 m band the centre is tested against

**Note** (§Resolution order step 6.8, and the layout table): the goal test is on
the ball **centre** against `y ∈ [9 m, 16 m]`, a 7 m mouth; the walls are "the
goal-line segments ... **outside the mouth**".

**Code**: `goalScoredBy` (`src/cogball/pitch.nim`) is exactly that test on the
centre against the full band. But two things stand in front of it in the same
substep, and both are physical:

* `resolveBallPosts` — the goalposts are static circles of radius 0.12 m at the
  mouth corners, so a ball of radius 0.35 m is pushed out whenever its centre
  comes within 0.47 m of a post centre;
* `resolveBallWalls` via `xBounds(y, radius)` — the goal plane opens for a body
  of radius `r` only while `y ∈ [9 m + r, 16 m − r]`, i.e. the aperture is
  inset by the body's own radius, which is what stops a ball whose *hull*
  overlaps the goal line from passing through it.

Measured, by firing the ball straight at the plane from 8 m out and stepping
until it scores (`GoalYMin` 9 000 000, `GoalYMax` 16 000 000, all in µm):

| ball speed | scores for centre y in | realised mouth |
|---|---|---|
| 200 000 µm/tick (4.8 m/s) | [9 380 000, 15 620 000] | 6.24 m |
| 500 000 µm/tick (12 m/s) | [9 290 000, 15 710 000] | 6.42 m |
| 1 000 000 µm/tick (24 m/s) | [9 230 000, 15 770 000] | 6.54 m |

**Why no change.** This is what a ball with a radius hitting a post with a
radius does; the note's 7 m describes the plane the *centre* is tested against,
which is exactly what the code tests. Widening the aperture would mean either
letting the ball's hull pass through the goal line or deleting the posts, and
it is a change to `sim.nim` — a `GameVersion` bump that invalidates every
recorded replay — for at most 0.35 m at each edge of a 7 m mouth. The number
is written down here instead, and `docs/RULES.md` states it for players.
