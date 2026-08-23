## The sim's shared vocabulary: the core constants (including GameVersion and
## its changelog), the gameplay/wire types, and the pure helpers both sides of
## every seam need. Split out of sim.nim exactly as coworld-ctf splits its own
## (docs/plans/2026-08-01-sim-split.md in the starter) so the leaf modules
## (rig_art, pitch, sim_config, sim_state, roster) share them without importing
## gameplay.
##
## MOVED VERBATIM in spirit from ctf: SimServer and friends are flatty-serialized
## POSITIONALLY into replay keyframes, so declaration/field order here is wire
## format — reorder nothing without a GameVersion bump.
##
## EVERY hashed field is an explicit fixed width (`int32` / `bool` / enum).
## Nim's `int` is 64-bit natively and 32-bit under `--cpu:wasm32`, and the same
## sim module compiles both ways (native server records, emscripten viewer
## re-simulates), so a bare `int` in hashed state is a native/wasm divergence
## waiting to happen. See docs/RULES.md §Determinism.

import
  std/random,
  pixie

const
  GameName* = "cogball"
  GameVersion* = "1"  ## GV1 (first rules): 3v3 robot soccer on a 40x25 m walled
    ## pitch. Integer micrometre physics at 24 Hz with four substeps a tick,
    ## Sprite v1 actuator masks as the recorded action log, a 120-tick coaching
    ## turn, kickoff freeze, the 240-tick stalemate neutral drop, mercy at a
    ## five-goal difference and a 690 s wall-clock stop.
    ##
    ## Prepend-only changelog, ctf's discipline: say what the number means and
    ## what it obsoletes, keeping the `GVnn (short rule name): HEADLINE` shape.
    ## `tools/ci/check_gameversion.sh` diffs this headline, not the digits.

  TargetFps* = 24
  ReplayFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]
    ## Replay/live playback speed steps. Kept from ctf verbatim: every
    ## speed-coupled layer (the transport keymap, the lull scan, the JS clients'
    ## wire constants) derives from this ONE table.

  # ---- world geometry, micrometres -----------------------------------------
  WorldW* = 44_000_000'i32     ## 44 m
  WorldH* = 25_000_000'i32     ## 25 m
  MapScale* = 40_000           ## micrometres per rendered map pixel.
  MapWidth* = 1100             ## WorldW div MapScale
  MapHeight* = 625             ## WorldH div MapScale

  PitchXMin* = 2_000_000'i32   ## the Azure goal plane.
  PitchXMax* = 42_000_000'i32  ## the Crimson goal plane.
  GoalYMin* = 9_000_000'i32
  GoalYMax* = 16_000_000'i32
  CentreX* = 22_000_000'i32
  CentreY* = 12_500_000'i32
  CentreCircleR* = 3_000_000'i32
  PenaltyDepth* = 8_000_000'i32   ## |x - own goal plane| bound of a penalty area.
  PenaltyHalfH* = 7_000_000'i32   ## |y - CentreY| bound of a penalty area.
  PostRadius* = 120_000'i32

  RobotRadius* = 550_000'i32
  BallRadius* = 350_000'i32
  RobotMassG* = 6000'i32
  BallMassG* = 450'i32
  KickReach* = 450_000'i32     ## slack past the two radii; see KickRange.
  KickRange* = RobotRadius + BallRadius + KickReach   ## 1 350 000 um
  KickImpulse* = 375_000'i32   ## 9.0 m/s along the heading.
  KickCooldownTicks* = 12'i32  ## 0.5 s
  RobotMaxSpeed* = 291_600'i32 ## 7.0 m/s
  BallMaxSpeed* = 1_041_600'i32 ## 25.0 m/s

  Substeps* = 4
  RobotCount* = 6
  SeatCount* = 2
  RobotsPerSeat* = 3

  # ---- physics tuning (all integer, all in the hash) ------------------------
  SpinAccel* = 6'i32           ## 1/16-brad per tick per tick of applied torque.
  SpinDampNum* = 64'i32        ## spin -= spin*64/1024 each substep.
  SpinMax* = 96'i32
  ThrustAccel* = 7800'i32      ## um/tick of speed added per substep, Q12-scaled.
  GripNum* = 85'i32            ## lateral scrub per substep, /1024.
  GripBrakeNum* = 255'i32      ## with ButtonSelect held.
  RobotDragNum* = 13'i32       ## /1024 per substep.
  BallDragNum* = 6'i32         ## /1024 per substep.
  WallRestitutionPct* = 25'i32     ## robot vs wall.
  RobotRestitutionPct* = 35'i32    ## robot vs robot.
  BallRobotRestitutionPct* = 55'i32
  DribbleTangentPct* = 80'i32
  PostRestitutionPct* = 70'i32
  BallWallRestitutionPct* = 80'i32
  BallWallTangentPct* = 98'i32

  # ---- match shape ----------------------------------------------------------
  DefaultMaxTicks* = 4800      ## 200 s = 3:20 at 24 Hz.
  DefaultTurnTicks* = 120      ## 5.0 s of sim time per coaching turn.
  DefaultTurnBudgetMs* = 9000
  DefaultAttempt1Ms* = 6000
  DefaultRetryMs* = 2500
  DefaultWallClockBudgetSeconds* = 690
  DefaultLobbyJoinTimeoutTicks* = 2400   ## 100 s of lobby ticks.
  DefaultStartWaitTicks* = 24
  DefaultGameOverTicks* = 120
  DefaultMercyGoalDiff* = 5
  DefaultStalemateTicks* = 240   ## 10 s parked ball -> neutral drop.
  StalemateBox* = 1_500_000'i32  ## um; the ball must leave this to reset it.
  DropClearRadius* = 3_000_000'i32
  KickoffFreezeTicks* = 25'i32
  AssistWindowTicks* = 96'i32
  PassWindowTicks* = 96'i32
  TouchThrottleTicks* = 6

  DefaultSeed* = 0xC0BA11
    ## The compiled-in default seed, and the "nobody chose a seed" sentinel a
    ## hosted variant config carries when it pins nothing (src/cogball.nim).
    ## Deliberately NOT 679961: that is the certification fixture's seed, and a
    ## fixture seed must be a real pin.
  DefaultMinPlayers* = 2
  MaxPlayers* = SeatCount
  DefaultMaxGames* = 1
  DefaultModel* = "claude-haiku-4-5-20251001"
  DefaultMaxOutputTokens* = 900

  # ---- reply caps (runes, never bytes) --------------------------------------
  MaxNoteRunes* = 160
  MaxSayRunes* = 48
  MaxPolicyRunes* = 48
  MaxDetailRunes* = 200
  MaxDirectiveRecordRunes* = 900
  MaxPromptRunes* = 4000
  MaxRobotIdRunes* = 8

  AimBradsTurn* = 256          ## brads per full turn; ctf's convention.
  HeadingQTurn* = 4096         ## headingQ resolution: 1/16 brad.

  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"
  ReplayWebSocketPath* = "/replay"
  RewardWebSocketPath* = "/reward"

type
  CogballError* = object of ValueError

  Seat* = enum
    ## Seat 0 defends x = PitchXMin and attacks +x; seat 1 mirrors it.
    ## Ordinals are wire format (flatty stores them positionally in replay
    ## keyframes): APPEND new members, never insert.
    Azure
    Crimson

  GamePhase* = enum
    Lobby
    Playing
    GameOver

  EndRule* = enum
    ## The detail behind `results.reason`; see docs/RULES.md §End conditions.
    erFullTime
    erMercy
    erWallClock
    erSimFault
    erHostError

  EndReason* = enum
    reasonComplete
    reasonDeadline
    reasonFault

  Role* = enum
    roleKeeper
    roleBack
    roleWing
    roleStriker

  Intent* = enum
    inChase
    inIntercept
    inHold
    inShoot
    inPass
    inClear
    inPress

  KickMode* = enum
    kickAuto
    kickNever

  DirectiveSource* = enum
    dsScripted
    dsLlm
    dsFallback

  PolicyKind* = enum
    pkScripted
    pkLlm

  RobotOrder* = object
    ## One robot's order for one coaching turn. Targets are world micrometres,
    ## already clamped into the pitch by the parser.
    role*: Role
    intent*: Intent
    targetX*, targetY*: int32
    passTo*: int32             ## robot index 0..5, -1 = none.
    kick*: KickMode
    say*: string               ## <= MaxSayRunes runes.

  Directive* = object
    ## A seat's active orders. NEVER mixed into gameHash (ctf's rule for
    ## damagePops/skin/puddleTicks): nothing a coach says can move the chain.
    turn*: int32
    source*: DirectiveSource
    note*: string              ## <= MaxNoteRunes runes.
    latencyMs*: int32
    robots*: array[RobotsPerSeat, RobotOrder]

  Robot* = object
    ## A wheeled robot. All positions/velocities are micrometres (and um/tick).
    x*, y*: int32
    vx*, vy*: int32
    headingQ*: int32           ## 0..4095, 1/16 brad. headingBrads = div 16.
    spin*: int32               ## 1/16 brad per tick.
    kickCooldown*: int32
    seat*: int32               ## 0 = Azure, 1 = Crimson.
    distanceUm*: int64         ## odometer; analysis only, not hashed.

  Ball* = object
    x*, y*: int32
    vx*, vy*: int32

  Touch* = object
    ## Bookkeeping for assists, passes and saves; not hashed.
    robot*: int32              ## -1 = nobody has touched the ball yet.
    seat*: int32
    tick*: int32

  ShotRecord* = object
    ## An in-flight shot on target awaiting its next touch (save detection).
    seat*: int32
    robot*: int32
    tick*: int32
    onTarget*: bool

  PassRecord* = object
    seat*: int32
    robot*: int32
    tick*: int32
    target*: int32

  SeatStats* = object
    goals*: int32
    shots*: int32
    shotsOnTarget*: int32
    saves*: int32
    possessionTicks*: int32
    kicks*: int32
    passesCompleted*: int32
    interceptions*: int32
    llmTurns*: int32
    fallbackTurns*: int32

  PickupPlaceholder* = object
    ## Reserved so future spawnables can append without shifting the keyframe
    ## layout; carries nothing today.
    present*: bool

  RewardAccount* = object
    address*: string
    slotIndex*: int32
    seat*: Seat
    hasSeat*: bool
    won*: bool
    abandoned*: bool
    reward*: int32
    games*: array[Seat, int32]
    wins*: array[Seat, int32]
    goals*: int32

  PlayerSlotConfig* = object
    name*: string
    token*: string
    team*: Seat
    hasTeam*: bool

  Player* = object
    ## One CONNECTION. Two per match; each drives a trio of robots.
    address*: string           ## the real policy name (spectator side only).
    joinOrder*: int32
    seat*: Seat
    policyLabel*: string       ## <= MaxPolicyRunes runes, from the register record.
    policyKind*: PolicyKind
    baseline*: string          ## scripted baseline name, "" for an LLM seat.
    registered*: bool
    reward*: int32

  SimEventKind* = enum
    ## Tier-2 analysis event channel (the Logs substrate). Analysis-only:
    ## never enters gameHash.
    Kick
    TouchEvent
    Shot
    Save
    Pass
    Interception
    Post
    Goal
    Kickoff
    Drop
    PhaseChange
    DirectiveEvent

  SimEvent* = object
    tick*: int
    kind*: SimEventKind
    source*: int               ## acting robot index, -1 = n/a.
    target*: int               ## affected robot index, -1 = n/a.
    seat*: int                 ## acting seat, -1 = n/a.
    amount*: int
    x*, y*: int32              ## world micrometres, -1 when not positional.
    speed*: int32              ## micrometres per tick.
    content*: string

  GameConfig* = object
    ## Every field a coworld variant may set. `sim_config.update` reads them;
    ## `configJson` echoes them into the replay header so playback re-derives
    ## the identical world. Adding a field here means adding it to
    ## `game.config_schema` in coworld_manifest_template.json in the same
    ## commit (tests/test_manifest.nim enforces it).
    seed*: int
    speed*: int
    numAgents*: int
    minPlayers*: int
    startWaitTicks*: int
    lobbyJoinTimeoutTicks*: int
    gameOverTicks*: int
    maxTicks*: int
    maxGames*: int
    turnTicks*: int
    turnBudgetMs*: int
    attempt1Ms*: int
    retryMs*: int
    wallClockBudgetSeconds*: int
    mercyGoalDiff*: int
    stalemateTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    closedRoster*: bool
    model*: string
    maxOutputTokens*: int
    kickImpulse*: int
    robotMaxSpeed*: int
    ballMaxSpeed*: int
    slots*: seq[PlayerSlotConfig]

  SimServer* = object
    ## Flatty-serialized POSITIONALLY into replay keyframes. Append only.
    config*: GameConfig
    players*: seq[Player]
    rewardAccounts*: seq[RewardAccount]
    robots*: array[RobotCount, Robot]
    ball*: Ball
    stats*: array[Seat, SeatStats]
    rng*: Rand
    nextJoinOrder*: int32
    tickCount*: int
    gameStartTick*: int
    startWaitTimer*: int
    lobbyWaitTimer*: int
    phase*: GamePhase
    winner*: Seat
    isDraw*: bool
    gameOverTimer*: int
    endReason*: EndReason
    endRule*: EndRule
    ended*: bool
    freezeUntil*: int32
    restartSeat*: int32
    stalemateTicks*: int32
    anchorX*, anchorY*: int32
    lastTouch*: Touch
    prevTouch*: Touch
    pendingShot*: ShotRecord
    pendingPass*: PassRecord
    needsReregister*: bool
    ## --- outside the hash from here on ---
    activeDirective*: array[Seat, Directive]
    hasDirective*: array[Seat, bool]
    trail*: seq[TrailPoint]    ## cosmetic ball trail; never hashed.
    kickFx*: seq[KickFx]       ## cosmetic kick rings; never hashed.
    goalFx*: seq[GoalFx]       ## cosmetic goal celebrations; never hashed.
    paint*: seq[PaintDot]      ## position-history turf paint; never hashed.
    feed*: seq[FeedLine]       ## broadcast match-feed rows; never hashed.
    gameEventLoggingEnabled*: bool
    collectEvents*: bool
    events*: seq[SimEvent]
    lastLobbyPlayersLogged*: int
    lastLobbyNeededLogged*: int
    lastLobbySecondsLogged*: int
    ## The most recent goal, kept for the broadcast channel. Set inside the
    ## hashed step, so the viewer re-derives it identically, but NOT hashed:
    ## the kickoff reset clears `lastTouch`, and the feed still has to be able
    ## to say who scored.
    lastGoalTick*: int32
    lastGoalSeat*: int32
    lastGoalBy*: int32
    lastGoalAssist*: int32
    lastGoalSpeed*: int32

  TrailPoint* = object
    x*, y*: int32
    tick*: int32
    seat*: int32               ## last toucher's seat, -1 = loose.

  KickFx* = object
    x*, y*: int32
    tick*: int32
    seat*: int32

  GoalFx* = object
    tick*: int32
    seat*: int32

  PaintDot* = object
    x*, y*: int32
    robot*: int32

  FeedLine* = object
    tick*: int32
    kind*: string
    seat*: int32
    text*: string

const
  AzureColor* = rgba(63, 124, 196, 255)   ## team cerulean; matches rig_real/blue.
  CrimsonColor* = rgba(224, 82, 58, 255)  ## team vermillion; matches rig_real/red.
  TurfDark* = rgba(38, 86, 46, 255)
  TurfLight* = rgba(46, 100, 54, 255)
  LineColor* = rgba(232, 240, 230, 235)
  BallColor* = rgba(244, 244, 238, 255)

  RobotHues*: array[RobotCount, int] = [190, 202, 214, 348, 0, 12]
    ## Per-robot paint hue. Azure 190/202/214, Crimson 348/0/12 — the
    ## position-history tinting the idea asks for, with no labels.

proc seatText*(seat: Seat): string {.inline.} =
  case seat
  of Azure: "azure"
  of Crimson: "crimson"

proc seatAlias*(seat: Seat): string {.inline.} =
  case seat
  of Azure: "Azure"
  of Crimson: "Crimson"

proc seatPrefix*(seat: Seat): string {.inline.} =
  case seat
  of Azure: "AZ"
  of Crimson: "CR"

proc robotId*(index: int): string {.inline.} =
  ## The in-game robot name: `AZ-1`..`AZ-3`, `CR-1`..`CR-3`. This is the ONLY
  ## robot identity a policy ever sees.
  let seat = if index < RobotsPerSeat: Azure else: Crimson
  seatPrefix(seat) & "-" & $((index mod RobotsPerSeat) + 1)

proc seatOfRobot*(index: int): Seat {.inline.} =
  if index < RobotsPerSeat: Azure else: Crimson

proc firstRobotOf*(seat: Seat): int {.inline.} =
  ord(seat) * RobotsPerSeat

proc attackDir*(seat: Seat): int32 {.inline.} =
  ## +1 when the seat attacks +x, -1 when it attacks -x.
  if seat == Azure: 1'i32 else: -1'i32

proc ownGoalX*(seat: Seat): int32 {.inline.} =
  if seat == Azure: PitchXMin else: PitchXMax

proc targetGoalX*(seat: Seat): int32 {.inline.} =
  if seat == Azure: PitchXMax else: PitchXMin

proc other*(seat: Seat): Seat {.inline.} =
  if seat == Azure: Crimson else: Azure

proc roleText*(role: Role): string {.inline.} =
  case role
  of roleKeeper: "keeper"
  of roleBack: "back"
  of roleWing: "wing"
  of roleStriker: "striker"

proc intentText*(intent: Intent): string {.inline.} =
  case intent
  of inChase: "chase"
  of inIntercept: "intercept"
  of inHold: "hold"
  of inShoot: "shoot"
  of inPass: "pass"
  of inClear: "clear"
  of inPress: "press"

proc kickText*(kick: KickMode): string {.inline.} =
  case kick
  of kickAuto: "auto"
  of kickNever: "never"

proc sourceText*(source: DirectiveSource): string {.inline.} =
  case source
  of dsScripted: "scripted"
  of dsLlm: "llm"
  of dsFallback: "fallback"

proc reasonText*(reason: EndReason): string {.inline.} =
  case reason
  of reasonComplete: "complete"
  of reasonDeadline: "deadline"
  of reasonFault: "fault"

proc endRuleText*(rule: EndRule): string {.inline.} =
  case rule
  of erFullTime: "full_time"
  of erMercy: "mercy"
  of erWallClock: "wall_clock"
  of erSimFault: "sim_fault"
  of erHostError: "host_error"

proc policyKindText*(kind: PolicyKind): string {.inline.} =
  case kind
  of pkScripted: "scripted"
  of pkLlm: "llm"

proc policyName*(address: string): string =
  ## The policy identity behind a connection address: the hosted runtime
  ## appends a per-seat " (N)" suffix to the same policy's several connections,
  ## and the join path turns spaces into underscores. Kept from ctf.
  result = address
  var cut = result.len
  var i = result.len - 1
  while i >= 0 and result[i] in {' ', '\t'}:
    dec i
  if i >= 0 and result[i] == ')':
    var j = i - 1
    while j >= 0 and result[j] in {'0' .. '9'}:
      dec j
    if j >= 0 and j < i - 1 and result[j] == '(':
      dec j
      while j >= 0 and result[j] in {' ', '_', '\t'}:
        dec j
      cut = j + 1
  if cut < result.len:
    result = result[0 ..< cut]

proc mapPxX*(x: int32): int {.inline.} = int(x) div MapScale
proc mapPxY*(y: int32): int {.inline.} = int(y) div MapScale
