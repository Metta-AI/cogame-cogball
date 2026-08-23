# Writing a cogball prompt

A cogball policy is a prompt. You are not writing motor commands; you are
writing a **coach**. Every five seconds of match time your prompt, plus the
current state of the pitch, goes to the model, and the model answers with one
directive for all three of your robots. A deterministic controller then
executes that directive at 30 Hz for the next five seconds.

So the question your prompt has to answer is: *given the ball here and my
three robots there, who does what?*

## What the model sees

Your prompt, then a blank line, then the seat's view as JSON: ball position,
velocity and speed; every robot's position, velocity, heading, speed and
distance to the ball; whether each of your robots' kickers are off cooldown;
the score; the clock; last turn's kick/shot counts and possession share; and
the directive you played last turn. It sees `Azure` / `Magenta` and robot ids
`AZ-1..3` / `MG-1..3` — never the real player behind the other seat.

## What it must answer

```json
{"note": "compact, keeper stays home",
 "robots": [
   {"id": "AZ-1", "role": "keeper", "intent": "hold", "target": [-17, 0.4],
    "pass_to": null, "kick": "auto", "say": "holding the arc"},
   {"id": "AZ-2", "role": "striker", "intent": "shoot", "target": [12, 1],
    "pass_to": null, "kick": "auto", "say": "going for goal"},
   {"id": "AZ-3", "role": "wing", "intent": "intercept", "target": [6, -5],
    "pass_to": null, "kick": "auto", "say": "running the channel"}]}
```

Exactly three entries, one per robot. The system prompt already states the
schema, so your prompt should spend its words on **tactics**, not on JSON.

## The seven intents, and what the controller actually does with each

| intent | the controller drives the robot to… | use it when |
| --- | --- | --- |
| `chase` | the ball itself | you just want a body on it |
| `intercept` | where the ball *will be* (up to 1.5 s of lead) | a loose ball, a cut-out |
| `hold` | your `target`, then turns to face the ball | keepers, backs, anyone who must not be dragged out |
| `shoot` | 0.9 m behind the ball on the line to their goal, then strikes | the ball is in front of goal |
| `pass` | 0.9 m behind the ball on the line to `pass_to` | you have a free teammate |
| `clear` | 0.9 m behind the ball on the line up the touchline | the ball is in your own box |
| `press` | the opponent nearest the ball, plus half a second of lead | you want to deny time, not win the ball |

`target` is used **directly** by `hold`; for every other intent it is a 20 %
bias on the steering point, which is how you nudge a chaser to favour one side
of the pitch. `kick: "never"` makes a robot shepherd the ball instead of
striking it — useful for a robot you want to keep possession with, expensive if
you use it on your striker.

## Five things that decide matches

1. **Never leave the goal empty.** One robot on `hold` at roughly
   `(±17, ball_y / 3)` covers the near post and is worth more than a third
   attacker. Every strong cogball prompt names a keeper every single turn.
2. **Robots are car-like.** Thrust acts along the heading and lateral velocity
   is scrubbed off by grip, so a robot that has to turn 180° loses about a
   second. Sending the *nearest* robot at the ball beats sending the *best*
   one.
3. **Rotate roles by distance, not by name.** The robot nearest the ball
   should be the one attacking it this turn, whichever id that is. Say so in
   the prompt: "the nearest robot always attacks, the deepest always keeps".
4. **A shot from outside 12 m is a giveaway.** The ball loses most of its pace
   in about three seconds; a long shot arrives slowly and hands over
   possession. Prefer `pass` to a supporting robot.
5. **Five seconds is a long time.** Whatever you order will still be running
   five seconds from now. Prefer intents that track the ball live (`chase`,
   `intercept`, `shoot`, `press`) for the robot near the action, and `hold`
   with an explicit target for the robots that should stay where they are.

## Things that will not work

- Micro-managing motors. There is no thrust or steering field; the controller
  owns that.
- Referring to "the last time we played" — nothing carries between episodes.
- Talking to the other seat. `note` and `say` are one-way, into the replay
  feed. (They are the only thing a spectator sees of your reasoning, so a good
  `note` is genuinely worth writing.)
- Asking for a formation by name. Say who holds where and who goes for the
  ball; the schema has no formation field.

## The two shipped champions

`cogball-total` plays total football: always a keeper, always a presser, a
third robot running ahead of the ball into space, roles rotating by distance,
and a preference for the pass over the low-percentage shot.

`cogball-counter` plays the counter: two robots behind the ball line holding
station, one pressing; the moment its team wins the ball, the presser shoots,
the back breaks wide, and only the keeper stays home. It never sends all three
robots past halfway.

Both are pure prompts against the same image and the same controller. If you
want to beat them, the fastest lever is not a cleverer shape — it is being
more decisive about *who* attacks and *who* stays.
