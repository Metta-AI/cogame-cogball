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

---

## `StalemateBox` is a HALF-width: the stalemate box is 3 m across

**Note** (§Resolution order step 8, §Neutral drop): "inside the **1 500 000 µm
box** anchored where the counter last reset".

**Code** (`src/cogball/sim.nim`, `sim_types.nim`): the test is
`abs(dx) <= StalemateBox and abs(dy) <= StalemateBox` with
`StalemateBox = 1_500_000`, so the counter runs while the ball stays inside a
**3 m × 3 m square** centred on the anchor — 1.5 m is the half-width, not the
side.

**Why it reads that way.** The note's phrase is ambiguous and the code had to
pick one. Half-width is the right pick: the anchor is re-set to the ball's own
position on every reset, so the quantity that matters is "how far can the ball
wander from where it was parked before we stop calling it parked", and that is
a radius. It also cannot be reached in one tick from the anchor —
`BallMaxSpeed` is 1 041 600 µm/tick — so the counter cannot be reset by a
single frame of jitter, which a 0.75 m half-width would allow.

Everything else in step 8 matches the note exactly: increment-then-compare
(`>=`) means the drop fires on the 240th consecutive tick, pinned by
`tests/test_physics.nim`.

---

## The kickoff freeze zeroes the BALL's velocity too

**Note** (§Resolution order step 2): "every robot's mask is forced to 0, every
velocity and `spin` is set to 0". The ball is not named.

**Code** (`src/cogball/sim.nim`, `stepPlaying`'s frozen branch): the six
robots' `vx`/`vy`/`spin` are zeroed **and** so are `sim.ball.vx`/`vy`.

**Why.** "Every velocity" is read as every velocity in the world, ball
included, which is what a frozen kickoff means: a ball that drifts while the
players cannot move is not a frozen restart. In practice it is already true —
the kickoff reset that precedes every freeze puts the ball on the centre spot
at rest — so the branch is a belt-and-braces invariant rather than a behaviour,
and it holds even if some future restart forgets to zero the ball. It is inside
the hashed step, so the viewer re-derives it identically.

---

## The jitter stream is drawn twice before the first played tick

**Note** (§Kickoff reset): "Each of the four flank robots gets a deterministic
y jitter of `sim.rng.rand(500_000) − 250_000`". It does not describe a second
draw.

**Code**: `kickoffReset` draws four values from the seeded sim RNG, and it runs
**twice** before a match starts — once at construction (`initSimServer`, which
must leave the bodies somewhere while the lobby fills) and once at `startGame`.
The placement a match actually kicks off from is the **second** draw set.

**Why it is harmless, and why it stays.** Determinism is unaffected, which is
the only property that matters here: the viewer reconstructs with
`initSimServer(config)` and re-steps from tick 0, so both draws happen in the
same order on both sides of the native/wasm boundary, and
`tests/test_physics.nim` pins the resulting coordinates against the seed.
Removing the construction-time reset would leave every body at (0, 0) through
the lobby, which the board would draw; skipping the RNG in it would make
`kickoffReset` two functions. Neither is worth a change to a hashed code path.

The one thing it did affect is now fixed: `initSimServer` clears
`lastKickoffTick` after the construction-time reset, so the placement that
happens before the match exists does not count as a kickoff for the broadcast
beat list.

---

## The neutral drop clears more state than the note enumerates

**Note** (§Neutral drop): "the ball teleports to the nearest of the four
neutral drop spots with zero velocity, every robot within 3 000 000 µm of that
spot is pushed radially out to exactly 3 000 000 µm with zero velocity,
`stalemateTicks` resets, and a `drop` event is emitted."

**Code** (`src/cogball/sim.nim`, `neutralDrop`): all of that, plus
`lastTouch`, `prevTouch`, `pendingShot` and `pendingPass` are reset, and the
stalemate anchor is moved to the drop spot.

**Why.** A drop is a restart, and those four fields are the possession chain
across a restart. Leaving them would credit a completed pass, an interception
or a save to a touch made ten seconds ago at the other end of the pitch, and
would let a shot registered before the drop be "saved" by whoever happened to
touch the ball after it. Moving the anchor is required, not optional: without
it the counter would be measured against the box the ball was just teleported
out of and would re-arm immediately.

All four fields are inside `gameHash`, so this is part of the recorded,
re-simulated truth the note requires the drop to be — it is simply more of it
than the note lists. `kickoffReset` clears exactly the same set, for exactly
the same reason.

---

## The robots are nano-banana cog sprites, not the rig_real segment rigs

**Note** (§Viewer, and the asset table): "robots are the shipped
`data/rig_real/blue` and `data/rig_real/red` wheeled rigs" composed by
`rig_art.nim` from nine segments and rotated to the heading.

**Code** (`src/cogball/rig_art.nim`, `data/art/cog_*.png`): each team is ONE
Gemini ("nano-banana") render of the canonical Softmax cog in a football kit —
Azure in a blue #7 jersey, headband and keeper gloves; Crimson in a red #9
jersey, crested helmet with a white plume and shin guards. The sprite is drawn
upright, 48 px tall at 1x, feet on the robot's position; the heading is a
tick on a team-coloured ground ellipse under the wheels. `data/rig_real/` is
deleted. The source sheet and the keying/splitting script are committed under
`scripts/art/`.

**Why.** The two rig_real liveries differed only by tint, so at board scale a
spectator told the teams apart by colour alone and the robots themselves did
not read as cogs. A kit per team (jersey number plate plus a large
team-coloured accessory) makes the sides distinct even with colour
discounted. Drawing the sprite upright instead of rotating it keeps the kit
readable at every heading; the ground tick carries the heading the rotation
used to. Nothing here touches the sim: the sprite is broadcast-only, outside
`gameHash`, no `GameVersion` bump. The lockerroom art (`client/art/lockerroom`)
is unchanged — it was already per-team character art, not a placeholder.
