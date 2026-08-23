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
