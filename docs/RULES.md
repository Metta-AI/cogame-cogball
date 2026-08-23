# Cogball — rules

Cogball is **3v3 robot soccer** on a walled indoor pitch in a continuous 2D
physics world. Two teams of three wheeled robots chase one ball and try to put
it through the opponent's goal mouth. Nothing is gridded: positions and
velocities are continuous fixed-point quantities, and the only discrete things
in the world are the tick, the actuator bits and the kick.

## Seats

`num_agents` is **2**. One seat is one full trio.

| seat | alias | robots | defends | attacks |
|---|---|---|---|---|
| 0 | Azure | `AZ-1` `AZ-2` `AZ-3` | view-x = −20 m | +x |
| 1 | Crimson | `CR-1` `CR-2` `CR-3` | view-x = +20 m | −x |

A seat does not drive motors. Every five seconds of match time it issues **one
directive** for all three of its robots, and a deterministic control layer
executes it for the next five seconds. See [COACHING.md](COACHING.md).

## The pitch

All world quantities are integer **micrometres** (µm) and **µm per tick**. The
coordinates a policy sees are **view coordinates**: metres from the centre spot,
`X = (x − 22 m)`, `Y = (y − 12.5 m)`, so the pitch is X ∈ [−20, +20],
Y ∈ [−12.5, +12.5].

| thing | value |
|---|---|
| world box | 44 m × 25 m |
| playing surface | 40 m × 25 m (x ∈ [2 m, 42 m]) |
| goal mouths | the planes x = 2 m and x = 42 m, y ∈ [9 m, 16 m] (7 m wide) |
| realised mouth for the ball | ~6.3 m: the goal test is on the ball CENTRE against the full 7 m band, but the posts (r = 0.12 m) and the goal-line aperture both hold a ball of radius 0.35 m off the last third of a metre at each edge |
| goal boxes | 2 m deep behind each mouth, closed on all sides |
| goalposts | static circles, r = 0.12 m, at the four mouth corners |
| penalty areas | Azure: x ≤ 8 m and \|y − 12.5 m\| ≤ 7 m; Crimson mirrored |
| centre spot / circle | (22 m, 12.5 m), r = 3 m |
| neutral drop spots | (11 m ‖ 33 m) × (6.5 m ‖ 18.5 m) |

**There is no out of play.** No throw-ins, no corners, no offside. The pitch is
fully walled.

## Bodies

Six robots: radius 0.55 m, mass 6000 g, each with a position, a velocity, a
heading (`headingQ`, 1/16 brad), a spin and a kick cooldown. One ball: radius
0.35 m, mass 450 g, position and velocity only — no spin, no Magnus effect.

Robots are car-like: thrust acts along the heading and lateral velocity is
scrubbed off by grip, so **facing the right way is part of the skill**.

## Time

24 ticks per second. A match is **4800 ticks = 200 s = 3:20**, divided into
**40 coaching turns of 120 ticks (5.0 s)**. Each tick integrates **four
substeps** of 1/96 s, so a 25 m/s ball moves at most 0.26 m per substep — less
than its own 0.70 m diameter, which is why nothing can tunnel.

## Actuators

A robot's action for one tick is exactly one **Sprite v1 input bitmask** — the
same `uint8` the replay records and the viewer replays.

| button | meaning |
|---|---|
| `ButtonUp` | thrust forward |
| `ButtonDown` | thrust reverse |
| `ButtonLeft` | torque counter-clockwise |
| `ButtonRight` | torque clockwise |
| `ButtonSelect` | brake (grip ×3 this tick; thrust is forced to 0) |
| `ButtonA` | kick |
| `ButtonB`, `ButtonC` | reserved, must be 0 |

Up+Down together is no thrust; Left+Right together is no torque.

## Resolution order

Every tick `t`, in this exact order, no exceptions:

1. **Turn boundary.** If `t mod 120 == 0` the directive collected for turn
   `t div 120` becomes each seat's active directive. Directives are **excluded
   from `gameHash`**: nothing a coach says can move the hash chain.
2. **Kickoff freeze.** If `t < freezeUntil`, every mask is forced to 0, every
   velocity and spin is zeroed, and steps 5–6 are skipped. The tick still
   advances, the hash is still written, the turn boundary still fires.
3. **Control compile.** For each robot in index order `AZ-1 … CR-3` the control
   layer reads the sim state plus that seat's directive and emits one mask.
4. **Record.** The six masks go to the sim and to the replay. **This is the
   determinism boundary.**
5. **Kicks.** In robot index order, for each robot with `ButtonA`, a zero
   cooldown, the ball within 1.35 m and inside a ±60° frontal arc: the ball's
   along-heading speed becomes `max(vpar, 0) + 9.0 m/s`, its perpendicular
   component is halved, the robot takes the mass-ratio reaction, and the
   cooldown is set to 12 ticks.
6. **Four substeps**, each in this order: robot integration (spin, heading,
   thrust, lateral grip, drag, speed cap, move) → ball integration → robot–wall
   → robot–robot → robot–ball → ball–post → ball–wall → goal test.
7. **Cooldowns** decrement.
8. **Stats and the stalemate counter.**
9. **Hash.** One `gameHash` per tick.
10. **Turn end.** Emit `turn_end`; mercy at a goal difference of 5; full time at
    `maxTicks`.

### Kickoff

Ball on the centre spot, everything at rest. Azure faces east, Crimson west.
The **restarting** seat (the conceding one; at match start `seed and 1`) places
its first robot 1.5 m behind the ball, the other seat's first robot 3.0 m away
on the far side, and the four flank robots at ±9.0 m on their own side at
12.5 m ± 4.5 m — each with a deterministic y jitter drawn from the seeded sim
RNG. Play resumes 25 ticks later.

### Neutral drop

With a fully walled pitch the corners are an absorbing state: a robot (r =
0.55 m) can never get corner-side of the ball (r = 0.35 m), and every push
drives it deeper. So the sim guarantees an escape. If the ball centre stays
inside a 1.5 m box for **240 ticks (10 s)**, it teleports to the nearest
neutral drop spot at rest, every robot within 3 m is pushed radially out to
exactly 3 m, and a `drop` event fires. The drop is inside `gameHash`: it is
part of the recorded, re-simulated truth, so no policy can defeat it. The
control layer's boards-escape rule (COACHING.md) is the first line; this is the
backstop.

### Shots, saves, passes

A kick whose post-kick velocity ray reaches the opponent goal plane inside the
mouth is a **shot on target**; a kick whose crossing lands within 4.5 m of the
mouth is a shot off target. A shot on target whose next touch is by a defending
robot inside its own penalty area is a **save**. A kick whose next touch is a
different robot of the same seat within 96 ticks is a **completed pass**; an
opponent touch is an **interception**. (Attribution is derived from state
alone — declared intent lives outside the determinism boundary.)

## Scoring

Team zero-sum and margin-sensitive; the two seats' scores always sum to 1.0:

```
gd(seat)    = goals[seat] − goals[1 − seat]
score(seat) = 0.5 + 0.5 · clamp(gd(seat) / 3, −1, +1)
```

**Higher is better.** 3–0 or better = 1.000; 2–0 = 0.833; 1–0 = 0.667; any draw
= 0.500. `win[seat] = gd(seat) > 0`. A `fault` episode scores 0.5 / 0.5 — an
infra fault is nobody's loss.

## End conditions

`results.reason` is a closed enum of three values; `results.endRule` carries the
detail.

| `reason` | `endRule` | when |
|---|---|---|
| `complete` | `full_time` | 4800 ticks played. The normal ending. |
| `complete` | `mercy` | goal difference ≥ 5 at a turn boundary. |
| `deadline` | `wall_clock` | `wallClockBudgetSeconds` (690) elapsed first. The score at that instant stands and the replay is complete up to the stop tick. |
| `fault` | `sim_fault` | a physics invariant guard tripped. 0.5 / 0.5. |
| `fault` | `host_error` | an unexpected server-side exception. 0.5 / 0.5. |

### Disconnects

A seat that never connects does **not** end the episode. After
`lobbyJoinTimeoutTicks` (2400 = 100 s) the no-show is reported to
`COGAME_PLAYER_FAILURE_URI`, its trio is driven by the `formation` baseline for
the whole match, and the match plays to full time. A seat that drops mid-match
keeps playing the same way and revives on reconnect. **No failure mode leaves a
robot unactuated.**

## Determinism

Replays are re-simulated by the **emscripten/wasm32** build of the same Nim
module the **native amd64** server ran, and their per-tick `gameHash` chain must
match exactly. That is true by construction, not by argument:

* every stored sim field is an explicit `int32` / `bool` / enum — never a bare
  `int`, which is 64-bit natively and 32-bit under `--cpu:wasm32`;
* every product or quotient of two sim quantities is taken in `int64` and
  narrowed with an explicit truncating `div` (Nim's `div` truncates toward zero,
  so the arithmetic is symmetric under negation — which is what makes the two
  ends of the pitch exactly fair);
* there is **no floating point** in `src/cogball/{sim,sim_types,sim_config,`
  `sim_state,pitch,control,trig}.nim`, grep-enforced by
  `tests/test_determinism.nim`;
* trigonometry is a committed literal table (`SinQ12`), the only square root is
  `isqrt`, and the only atan2 is `bradsOfVectorI` — all integer, all in
  `src/cogball/trig.nim`;
* the only randomness is the seeded sim RNG, used for exactly one thing: the
  kickoff y-jitter.

CI proves the cross-build equality on every push: the `wasm-viewer` job runs
`node tools/wasm_replay_smoke.cjs dist/static-replay-viewer <fixture> 300`,
which fails if `cogball_mismatch_tick() != -1`.

## Out of scope (v1)

The 6-seat hero-per-seat variant; raw per-tick actuator control by an external
policy; Box2D, joints, polygons, friction cones and ball spin; every soccer rule
beyond the goal (throw-ins, corners, offside, fouls, cards, penalties, keeper
handling, added time); robot heterogeneity; mid-turn interruption; inter-seat
chat; player debug-sprite overlays; audio, 3D and camera cuts other than the
slow-mo goal replay; persistent memory across episodes; campaign mode.
