/* cogball physics constants — the single source shared by the sim build
 * (sim/build_sim.sh -> build/cogball_sim.wasm, hosted by wasmtime) and the
 * viewer build (sim/build_viewer.sh -> viewer/dist + build/viewer_core.js),
 * so the two can never drift. Every value is quoted from
 * docs/plans/2026-08-22-cogball-design.md "The game".
 *
 * Units are metres, seconds, kilograms. Every quantity below is a `double`
 * literal: the physics core uses only + - * / and sqrt on doubles, which
 * WebAssembly specifies exactly, which is what makes the server build and
 * the browser build bit-identical.
 */
#ifndef COGBALL_CONFIG_H
#define COGBALL_CONFIG_H

/* -- topology --------------------------------------------------------- */
#define CB_SEATS 2
#define CB_ROBOTS_PER_SEAT 3
#define CB_NUM_ROBOTS 6

/* -- time ------------------------------------------------------------- */
#define CB_TICKS_PER_SECOND 30
#define CB_SUBSTEPS 4
#define CB_HS (1.0 / 120.0) /* substep length: dt / CB_SUBSTEPS */
#define CB_TURN_TICKS 150   /* decision turn = 5.0 s of sim time */
#define CB_KEYFRAME_EVERY 30

/* -- pitch ------------------------------------------------------------ */
#define CB_PITCH_X 20.0        /* |x| <= 20 interior                       */
#define CB_PITCH_Y 12.5        /* |y| <= 12.5 interior                     */
#define CB_GOAL_HALF_WIDTH 3.5 /* goal mouth is |y| <= 3.5 at x = +-20     */
#define CB_GOAL_BACK 22.0      /* goal box is closed at |x| = 22           */
#define CB_POST_R 0.12         /* static post circles at (+-20, +-3.5)     */
#define CB_PENALTY_X 14.0      /* own penalty area: |x| >= 14 on own side  */
#define CB_PENALTY_Y 7.0       /* ... and |y| <= 7                         */

/* -- bodies ----------------------------------------------------------- */
#define CB_ROBOT_R 0.55
#define CB_ROBOT_M 6.0
#define CB_BALL_R 0.35
#define CB_BALL_M 0.45

/* -- robot drive ------------------------------------------------------ */
#define CB_TURN_ACCEL 24.0     /* omega' = TURN_ACCEL*u_turn - TURN_DAMP*omega */
#define CB_TURN_DAMP 6.0
#define CB_OMEGA_MAX 6.0
#define CB_THRUST 18.0         /* along the heading                        */
#define CB_GRIP 8.0            /* lateral velocity scrub                   */
#define CB_LINEAR_DAMP 1.2
#define CB_ROBOT_MAX_SPEED 7.0

/* -- ball ------------------------------------------------------------- */
#define CB_BALL_DAMP 0.6
#define CB_BALL_MAX_SPEED 30.0

/* -- kick ------------------------------------------------------------- */
/* reach = robot radius + ball radius + 0.45 m of stick */
#define CB_KICK_RANGE 1.35
#define CB_KICK_DOT 0.5
#define CB_KICK_SPEED 9.0
#define CB_KICK_COOLDOWN 12

/* -- contacts --------------------------------------------------------- */
#define CB_REST_ROBOT_WALL 0.25
#define CB_REST_ROBOT_ROBOT 0.35
#define CB_REST_BALL_ROBOT 0.55
#define CB_DRIBBLE_TANGENT 0.80
#define CB_REST_BALL_POST 0.70
#define CB_REST_BALL_WALL 0.80
#define CB_BALL_WALL_TANGENT 0.98

/* -- restarts --------------------------------------------------------- */
/* after a goal at tick t: freeze_until = t + 31 (the rest of tick t plus
 * 30 fully frozen ticks == 1.0 s of kickoff freeze) */
#define CB_FREEZE_TICKS 31

/* -- event ring ------------------------------------------------------- */
/* Drained by the host every tick; one tick can plausibly emit six touches,
 * six kicks, a post, a goal and a kickoff. 256 is two orders of margin. */
#define CB_EVENT_CAP 256
#define CB_EVENT_FIELDS 12

/* event type codes (CbEvent.f[0]) */
#define CB_EV_KICK 1.0
#define CB_EV_TOUCH 2.0
#define CB_EV_POST 3.0
#define CB_EV_GOAL 4.0
#define CB_EV_KICKOFF 5.0

/* -- packed state buffer (cogball_state_ptr) -------------------------- */
/* [0..3]  ball x, y, vx, vy
 * [4 + 8*i .. ] robot i: x, y, vx, vy, hx, hy, omega, cooldown
 * [52] last_touch_robot   [53] last_touch_seat  [54] last_touch_tick
 * [55] freeze_until       [56] goals[0]         [57] goals[1]
 * [58] tick               [59] fault
 */
#define CB_STATE_BALL 0
#define CB_STATE_ROBOT0 4
#define CB_STATE_ROBOT_STRIDE 8
#define CB_STATE_FIELDS 60

#endif /* COGBALL_CONFIG_H */
