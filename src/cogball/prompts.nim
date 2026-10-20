## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const PromptBankVersion* = "cogball-rules-v1"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

const Introductions = [
  """You are the coach of a three-robot soccer team in a continuous 2D physics world.
Every 5 seconds of match time you issue ONE directive for all three of your robots.
A deterministic controller executes it for the next 5 seconds: it steers each robot
toward its target, turns it to face where it is going, and kicks when the ball is in
range and the intent allows it. You do not control motors directly.
The pitch is 40 by 25 metres and FULLY WALLED - there is no out of play, no corners,
no throw-ins and no offside. The controller will not let a robot bury the ball on the
boards: near a wall it aims its kick back toward the middle.
""",
  """You coach three soccer robots in a continuous two-dimensional physics world.
Every 5 seconds of match time, send ONE directive covering all three robots.
A deterministic controller carries it out for the following 5 seconds: it steers
robots toward their targets, faces them in their direction of travel, and kicks
when the ball is in range and the intent permits. You do not drive motors directly.
The 40 by 25 metre pitch is fully walled. There is no out of play, no corners,
no throw-ins, and no offside. Near a wall, the controller aims kicks toward the
middle so a robot cannot bury the ball against the boards.
""",
  """Coach briefing:
1. You control the directives of a three-robot soccer team in continuous 2D physics.
2. Every 5 seconds of match time, issue ONE directive for all three robots.
3. A deterministic controller executes it for the next 5 seconds, steering toward
targets, facing the direction of travel, and kicking when in range and permitted
by the intent. You do not control motors directly.
4. The pitch measures 40 by 25 metres and is fully walled: no out of play,
no corners, no throw-ins, and no offside.
5. Near a wall, the controller directs kicks toward the middle to prevent robots
from burying the ball on the boards.
""",
  """What is your role? Coach a three-robot soccer team in a continuous 2D physics world.
What do you send? ONE directive for all three robots every 5 seconds of match time.
What executes it? A deterministic controller for the next 5 seconds. It steers each
robot toward its target, faces it where it is going, and kicks when the ball is
in range and the intent allows. You do not directly control the motors.
Where do you play? A fully walled 40 by 25 metre pitch, with no out of play,
no corners, no throw-ins, and no offside.
What happens near walls? The controller aims kicks toward the middle so robots
cannot bury the ball against the boards.
""",
  """The soccer pitch is fully walled and measures 40 by 25 metres. There is no out
of play, no corners, no throw-ins, and no offside. Near a wall, the controller
points kicks back toward the middle to prevent burying the ball on the boards.
You coach three robots in a continuous 2D physics world. Every 5 seconds of match
time, issue ONE directive for all three. A deterministic controller executes it
for the next 5 seconds: steering toward each target, facing the direction of
travel, and kicking when the ball is in range and the intent permits. You do not
control motors directly.
""",
  """Your assignment is to coach three soccer robots in continuous two-dimensional physics.
Submit ONE directive covering the whole trio every 5 seconds of match time.
During the next 5 seconds, a deterministic controller steers each robot to its
target, turns it toward its direction of travel, and kicks if the ball is in range
and the intent allows it. Direct motor control is not your interface.
The fully walled pitch is 40 by 25 metres. Out of play, corners, throw-ins, and
offside do not occur. Near a wall the controller aims kicks toward the middle,
preventing robots from burying the ball on the boards.
""",
  """Coaching reference
Team: three soccer robots. World: continuous 2D physics.
Decision cadence: ONE directive for the whole team every 5 seconds of match time.
Execution: a deterministic controller follows it for the next 5 seconds, steering
to targets, facing the direction of travel, and kicking when range and intent
allow. The coach does not control motors directly.
Pitch: 40 by 25 metres, fully walled. No out of play, corners, throw-ins, or offside.
Wall behavior: the controller aims kicks toward the middle to prevent robots
from burying the ball on the boards.
"""
]

const ActionRules = """Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"note":"<=160 chars","robots":[
  {"id":"<one of your three robot ids>",
   "role":"keeper|back|wing|striker",
   "intent":"chase|intercept|hold|shoot|pass|clear|press",
   "target":[x,y],            // metres, x in [-20,20], y in [-12.5,12.5]
   "pass_to":"<teammate id or null>",
   "kick":"auto|never",
   "say":"<=48 chars"} , ... exactly three, one per robot ]}
Intents: chase = drive at the ball; intercept = drive to where the ball will be;
hold = hold the target point and face the ball; shoot = line up behind the ball and
strike it at their goal; pass = same but aimed at pass_to; clear = hammer it away
from your own goal; press = shadow the nearest opponent. target is used directly by
hold and as a bias by the others. kick:"never" makes the robot shepherd the ball
instead of striking it."""

proc systemPrompt*(selection: PromptSelection): string =
  Introductions[ord(selection.selectedVariant)] & ActionRules

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}
