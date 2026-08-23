# Writing a cogball prompt

A cogball policy is a **prompt**. You do not drive motors, and you do not write
code: you coach. Every five seconds of match time the game server sends your
prompt, plus the state of the pitch, to Claude and asks for one JSON directive
for all three of your robots. A deterministic control layer then executes that
directive for the next five seconds.

Forty turns, one directive each. That is the whole game from your side.

## What your coach is told

The system prompt is fixed and identical for both champions. Your prompt is
appended under a **GUIDANCE FROM YOUR OPERATOR** heading, then the seat's view
of the pitch:

```json
{"turn": 7, "of": 40, "clock": {"played_s": 35.0, "left_s": 165.0},
 "score": {"you": 1, "them": 0},
 "you": {"alias": "Azure", "attacking_x": "+20", "defending_x": "-20"},
 "pitch": {"x_min": -20, "x_max": 20, "y_min": -12.5, "y_max": 12.5,
           "goal_half_width": 3.5, "your_penalty_area": "x <= -14, |y| <= 7",
           "walled": true},
 "ball": {"pos": [3.21, -1.04], "vel": [4.10, 0.62], "speed": 4.15,
          "possession": "AZ-2", "in_your_half": false, "on_boards": false},
 "your_robots": [{"id": "AZ-1", "pos": [-16.9, 0.4], "vel": [0.2, -0.1],
                  "facing": [1.0, 0.0], "speed": 0.22, "kick_ready": true,
                  "dist_to_ball": 20.1, "last_role": "keeper"}, "… 3 …"],
 "their_robots": [{"id": "CR-1", "pos": [7.7, 2.1], "vel": [-3.0, 0.4],
                   "facing": [-0.99, 0.13], "speed": 3.03,
                   "dist_to_ball": 5.6}, "… 3 …"],
 "last_turn": {"your_kicks": 2, "their_kicks": 1, "your_shots": 1,
               "their_shots": 0, "possession_pct_you": 63,
               "goals": [{"tick": 890, "by": "AZ-3", "for": "you"}]},
 "your_last_directive": "… what you played last turn, or null on turn 0 …"}
```

Everything is in **view coordinates**: metres from the centre spot. Your own
goal and the one you attack are named for you every turn, so a prompt never has
to remember which side it is on.

## The directive

```json
{"note": "compact, keeper stays home",
 "robots": [{"id": "AZ-1", "role": "keeper", "intent": "hold",
             "target": [-17.0, 0.4], "pass_to": null,
             "kick": "auto", "say": "holding the arc"}, "… 3 …"]}
```

| field | legal values | repaired to |
|---|---|---|
| `note` | ≤ 160 runes | truncated |
| `robots` | exactly your three robots | extras dropped; missing filled from last turn, else from `formation` |
| `id` | `AZ-1..3` / `CR-1..3`, case-insensitive | unmatched ids assigned by position |
| `role` | `keeper` `back` `wing` `striker` | `wing` |
| `intent` | `chase` `intercept` `hold` `shoot` `pass` `clear` `press` | `chase` |
| `target` | `[x, y]` metres | clamped into the pitch; missing → the robot's current position |
| `pass_to` | a *teammate* id ≠ self | `null` (and `pass` degrades to `shoot`) |
| `kick` | `auto` `never` | `auto` |
| `say` | ≤ 48 runes | truncated |

Parsing is deliberately forgiving: markdown fences, a prose prefix, an
id-keyed `robots` object, numeric strings and unknown enums all repair. Only
when no usable robot entry can be recovered at all does the turn retry once,
and then fall back to the `formation` baseline.

## What each intent actually does

The control layer is the same code for every policy, so two prompts are
strictly comparable.

| intent | the robot… |
|---|---|
| `chase` | drives at the ball |
| `intercept` | drives to where the ball will be (lead time from the closing speed) |
| `hold` | holds `target` and turns to face the ball once it arrives |
| `shoot` | lines up 0.9 m behind the ball on the goal side and strikes it |
| `pass` | the same, aimed at `pass_to`'s leading position |
| `clear` | the same, aimed away from your own goal toward a touchline |
| `press` | shadows the opponent nearest the ball |

`target` is used **directly** by `hold` and as a 20 % bias by everything else,
so it is a useful nudge even on `chase`. `kick: "never"` makes a robot shepherd
the ball instead of striking it — useful for a keeper you want between the ball
and the goal rather than swinging at it.

**The boards-escape rule overrides you.** When the ball hugs a wall outside the
goal-mouth corridor, the closest robot of your trio aims its kick back toward
the middle and kicks even if you said `never`; its two teammates are pushed
3 m off the boards so a whole trio cannot pile into one corner. The sim also
drops the ball on a neutral spot if it has not moved 1.5 m in 10 s. You cannot
turn either off, and you should not want to: a buried ball is a 0–0.

## What actually wins

Things that show up in the replays:

* **Never leave your goal empty.** One robot with `role: "keeper"` and
  `intent: "hold"` on the arc ~3 m in front of your line, with its `y` tracking
  about a third of the ball's `y`, is worth more than a third attacker.
* **Rotate by distance, not by name.** The nearest robot attacks; the deepest
  keeps. Re-assign the roles every turn from `dist_to_ball`.
* **Shoot from inside 12 m, pass from outside it.** A long shot is a free
  clearance for the other side; a pass to a robot already in space is not.
* **Use the whole 5 seconds.** A directive is a *plan*, not a twitch. Sending
  three robots at the ball wastes the turn — that is exactly what the `swarm`
  baseline does, and it loses.
* **Watch `on_boards`.** When it is true, send exactly one robot at the ball and
  keep the others in open space to collect the clearance.
* **Say something.** `note` and `say` appear in the broadcast feed. They cost
  nothing and they are how a spectator sees you playing.

## Fielding a policy

Reuse the shipped image and set one environment variable:

```bash
coworld upload-policy coworld-cogball:latest \
  --name my-cogball \
  --run /bin/cogball-player \
  --secret-env PLAYER_PROMPT="<your strategy>"
```

`PLAYER_SCRIPTED=formation` or `PLAYER_SCRIPTED=swarm` fields a built-in
baseline instead — the same directive shape, no LLM, microseconds per turn.

## Degrading

Every wait is bounded. Both seats' calls go out as **one parallel batch** per
turn with a 6.0 s deadline; anything that timed out, errored, returned non-JSON
or returned no usable robot entry is retried **once** as a single batch with a
2.5 s deadline, all inside a 9.0 s monotonic per-turn cap. (The transport
takes whole seconds and a batch in flight cannot be interrupted, so each
allowance is floored before it is handed over: 6 s + 2 s = 8 s realised worst
case.) Two consecutive
failures play the `formation` directive and write a `fallback` record naming the
cause. If the wall clock gets close to the budget, a `budget_guard` record fires
and the rest of the match runs on the scripted layer, so the episode ends
`complete/full_time` rather than `deadline`.

None of that is a punishment: it is why a slow model never costs you the match.
