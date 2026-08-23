/* cogball deterministic physics core.
 *
 * A purpose-written 3v3 soccer world: six circular robots with a heading
 * and a kick, one ball, walls, two goals. Roughly 400 lines, because that
 * is all a circle-circle / circle-wall world needs — and because the
 * alternative (vendoring Box2D) would make the replay guarantee depend on
 * two different musl builds agreeing about sinf. See
 * docs/plans/2026-08-22-cogball-design.md "Sim module".
 *
 * ARITHMETIC DISCIPLINE. Only + - * / sqrt on doubles, comparisons, and
 * integer ops. No libm call, no `float`, no -ffast-math (both build scripts
 * are grepped for it). WebAssembly specifies f64.add/sub/mul/div/sqrt
 * exactly and forbids contraction, so the standalone build under wasmtime
 * and the emscripten build in the browser produce bit-identical state.
 * tests/test_determinism.py is the gate that proves it and the source guard
 * that keeps it true.
 *
 * Heading rotation is DEFINED as "rotate first-order by omega*hs, then
 * renormalise" (see step_robot). It is not an approximation of a sin/cos
 * call, so there is no reference behaviour it can drift from.
 */

#include "cogball_core.h"

#define cb_sqrt __builtin_sqrt

/* -- world ------------------------------------------------------------ */

typedef struct {
    double bx, by, bvx, bvy;
    double rx[CB_NUM_ROBOTS], ry[CB_NUM_ROBOTS];
    double vx[CB_NUM_ROBOTS], vy[CB_NUM_ROBOTS];
    double hx[CB_NUM_ROBOTS], hy[CB_NUM_ROBOTS];
    double om[CB_NUM_ROBOTS];
    int cool[CB_NUM_ROBOTS];
    int goals[CB_SEATS];
    int tick;
    int freeze_until;
    int last_touch_robot;
    int last_touch_seat;
    int last_touch_tick;
    int fault;
    unsigned long long rng_state;
    unsigned long long rng_inc;
} CbWorld;

static CbWorld W;
static unsigned char g_ctl[CB_NUM_ROBOTS * 3];
static CbEvent g_events[CB_EVENT_CAP];
static int g_event_count;
static double g_state[CB_STATE_FIELDS];

/* -- PCG32 (integer arithmetic only; kickoff jitter is its only user) -- */

static unsigned int pcg32(void)
{
    unsigned long long old = W.rng_state;
    W.rng_state = old * 6364136223846793005ULL + W.rng_inc;
    unsigned int xorshifted = (unsigned int)(((old >> 18u) ^ old) >> 27u);
    unsigned int rot = (unsigned int)(old >> 59u);
    return (xorshifted >> rot) | (xorshifted << ((0u - rot) & 31u));
}

static void pcg32_seed(unsigned int seed)
{
    W.rng_state = 0ULL;
    W.rng_inc = (((unsigned long long)seed << 1u) | 1ULL);
    (void)pcg32();
    W.rng_state += 0x853c49e6748fea9bULL ^ (unsigned long long)seed;
    (void)pcg32();
}

/* Deterministic +-0.25 m of kickoff y-jitter. 2^32 is exact in double. */
static double jitter(void)
{
    return ((double)pcg32() / 4294967296.0) * 0.5 - 0.25;
}

/* -- small helpers ---------------------------------------------------- */

static int seat_of(int robot) { return robot / CB_ROBOTS_PER_SEAT; }

/* -1.0 for seat 0 (Azure defends x = -20), +1.0 for seat 1. */
static double own_dir(int seat) { return seat == 0 ? -1.0 : 1.0; }

static double clampd(double v, double lo, double hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static void emit(double type, int robot, int seat, int aux,
                 double p0, double p1, double p2, double p3,
                 double p4, double p5)
{
    CbEvent *e;
    if (g_event_count >= CB_EVENT_CAP) return;
    e = &g_events[g_event_count++];
    e->f[0] = type;
    e->f[1] = (double)robot;
    e->f[2] = (double)seat;
    e->f[3] = (double)aux;
    e->f[4] = p0;
    e->f[5] = p1;
    e->f[6] = p2;
    e->f[7] = p3;
    e->f[8] = p4;
    e->f[9] = p5;
    e->f[10] = 0.0;
    e->f[11] = 0.0;
}

/* -- kickoff ---------------------------------------------------------- */

/* Exact reset from the design note: ball on the spot, everything stopped,
 * the restarting (conceding) seat 1.5 m from the ball on its own side, the
 * other seat 3.0 m away on theirs, wide robots at +-9 m with jitter. */
static void kickoff(int restart_seat)
{
    int other = 1 - restart_seat;
    int i;
    int rbase = restart_seat * CB_ROBOTS_PER_SEAT;
    int obase = other * CB_ROBOTS_PER_SEAT;
    double j1, j2, j3, j4;

    W.bx = 0.0;
    W.by = 0.0;
    W.bvx = 0.0;
    W.bvy = 0.0;
    for (i = 0; i < CB_NUM_ROBOTS; i++) {
        W.vx[i] = 0.0;
        W.vy[i] = 0.0;
        W.om[i] = 0.0;
        W.cool[i] = 0;
        /* Azure attacks +x, Magenta attacks -x. */
        W.hx[i] = seat_of(i) == 0 ? 1.0 : -1.0;
        W.hy[i] = 0.0;
    }

    j1 = jitter();
    j2 = jitter();
    j3 = jitter();
    j4 = jitter();

    W.rx[rbase + 0] = own_dir(restart_seat) * 1.5;
    W.ry[rbase + 0] = 0.0;
    W.rx[rbase + 1] = own_dir(restart_seat) * 9.0;
    W.ry[rbase + 1] = 4.5 + j1;
    W.rx[rbase + 2] = own_dir(restart_seat) * 9.0;
    W.ry[rbase + 2] = -4.5 + j2;

    W.rx[obase + 0] = own_dir(other) * 3.0;
    W.ry[obase + 0] = 0.0;
    W.rx[obase + 1] = own_dir(other) * 9.0;
    W.ry[obase + 1] = 4.5 + j3;
    W.rx[obase + 2] = own_dir(other) * 9.0;
    W.ry[obase + 2] = -4.5 + j4;

    W.last_touch_robot = -1;
    W.last_touch_seat = -1;
    W.last_touch_tick = -1;

    emit(CB_EV_KICKOFF, -1, -1, restart_seat, 0, 0, 0, 0, 0, 0);
}

/* -- substep pieces --------------------------------------------------- */

static void step_robot(int i, double u_thrust, double u_turn)
{
    double om, delta, nhx, nhy, len, ax, ay, along, lat_x, lat_y, speed;

    om = W.om[i] + (CB_TURN_ACCEL * u_turn - CB_TURN_DAMP * W.om[i]) * CB_HS;
    om = clampd(om, -CB_OMEGA_MAX, CB_OMEGA_MAX);
    W.om[i] = om;

    /* First-order rotate + renormalise: the DEFINITION of this sim's
     * rotation (uses only + - * / sqrt, so it cannot drift across
     * toolchains the way a sinf/cosf pair would). */
    delta = om * CB_HS;
    nhx = W.hx[i] - delta * W.hy[i];
    nhy = W.hy[i] + delta * W.hx[i];
    len = cb_sqrt(nhx * nhx + nhy * nhy);
    if (len > 0.0) {
        W.hx[i] = nhx / len;
        W.hy[i] = nhy / len;
    }

    along = W.vx[i] * W.hx[i] + W.vy[i] * W.hy[i];
    lat_x = W.vx[i] - along * W.hx[i];
    lat_y = W.vy[i] - along * W.hy[i];
    ax = CB_THRUST * u_thrust * W.hx[i] - CB_GRIP * lat_x;
    ay = CB_THRUST * u_thrust * W.hy[i] - CB_GRIP * lat_y;

    W.vx[i] = (W.vx[i] + ax * CB_HS) * (1.0 - CB_LINEAR_DAMP * CB_HS);
    W.vy[i] = (W.vy[i] + ay * CB_HS) * (1.0 - CB_LINEAR_DAMP * CB_HS);

    speed = cb_sqrt(W.vx[i] * W.vx[i] + W.vy[i] * W.vy[i]);
    if (speed > CB_ROBOT_MAX_SPEED) {
        W.vx[i] = W.vx[i] * CB_ROBOT_MAX_SPEED / speed;
        W.vy[i] = W.vy[i] * CB_ROBOT_MAX_SPEED / speed;
    }

    W.rx[i] = W.rx[i] + W.vx[i] * CB_HS;
    W.ry[i] = W.ry[i] + W.vy[i] * CB_HS;
}

static void step_ball(void)
{
    double speed;
    W.bvx = W.bvx * (1.0 - CB_BALL_DAMP * CB_HS);
    W.bvy = W.bvy * (1.0 - CB_BALL_DAMP * CB_HS);
    speed = cb_sqrt(W.bvx * W.bvx + W.bvy * W.bvy);
    if (speed > CB_BALL_MAX_SPEED) {
        W.bvx = W.bvx * CB_BALL_MAX_SPEED / speed;
        W.bvy = W.bvy * CB_BALL_MAX_SPEED / speed;
    }
    W.bx = W.bx + W.bvx * CB_HS;
    W.by = W.by + W.bvy * CB_HS;
}

/* Robots live inside the pitch rectangle only: they never enter the goal
 * boxes (the mouth is ball-sized business). Restitution 0.25. */
static void robot_walls(int i)
{
    double lim_x = CB_PITCH_X - CB_ROBOT_R;
    double lim_y = CB_PITCH_Y - CB_ROBOT_R;
    if (W.rx[i] > lim_x) {
        W.rx[i] = lim_x;
        if (W.vx[i] > 0.0) W.vx[i] = -W.vx[i] * CB_REST_ROBOT_WALL;
    } else if (W.rx[i] < -lim_x) {
        W.rx[i] = -lim_x;
        if (W.vx[i] < 0.0) W.vx[i] = -W.vx[i] * CB_REST_ROBOT_WALL;
    }
    if (W.ry[i] > lim_y) {
        W.ry[i] = lim_y;
        if (W.vy[i] > 0.0) W.vy[i] = -W.vy[i] * CB_REST_ROBOT_WALL;
    } else if (W.ry[i] < -lim_y) {
        W.ry[i] = -lim_y;
        if (W.vy[i] < 0.0) W.vy[i] = -W.vy[i] * CB_REST_ROBOT_WALL;
    }
}

static void robot_pair(int i, int j)
{
    double dx = W.rx[j] - W.rx[i];
    double dy = W.ry[j] - W.ry[i];
    double d2 = dx * dx + dy * dy;
    double min_d = 2.0 * CB_ROBOT_R;
    double d, nx, ny, half, vn, imp;
    if (d2 >= min_d * min_d) return;
    d = cb_sqrt(d2);
    if (d > 0.0) {
        nx = dx / d;
        ny = dy / d;
    } else {
        /* Exactly coincident centres: separate along +x deterministically. */
        nx = 1.0;
        ny = 0.0;
        d = 0.0;
    }
    half = (min_d - d) * 0.5;
    W.rx[i] = W.rx[i] - nx * half;
    W.ry[i] = W.ry[i] - ny * half;
    W.rx[j] = W.rx[j] + nx * half;
    W.ry[j] = W.ry[j] + ny * half;

    vn = (W.vx[j] - W.vx[i]) * nx + (W.vy[j] - W.vy[i]) * ny;
    if (vn >= 0.0) return; /* separating already */
    /* Equal masses: the impulse splits evenly. */
    imp = -(1.0 + CB_REST_ROBOT_ROBOT) * vn * 0.5;
    W.vx[i] = W.vx[i] - imp * nx;
    W.vy[i] = W.vy[i] - imp * ny;
    W.vx[j] = W.vx[j] + imp * nx;
    W.vy[j] = W.vy[j] + imp * ny;
}

static void robot_ball(int i)
{
    double dx = W.bx - W.rx[i];
    double dy = W.by - W.ry[i];
    double d2 = dx * dx + dy * dy;
    double min_d = CB_ROBOT_R + CB_BALL_R;
    double inv_r = 1.0 / CB_ROBOT_M;
    double inv_b = 1.0 / CB_BALL_M;
    double d, nx, ny, pen, share_r, share_b, rel_x, rel_y, vn, jimp;
    double tx, ty;
    if (d2 >= min_d * min_d) return;
    d = cb_sqrt(d2);
    if (d > 0.0) {
        nx = dx / d;
        ny = dy / d;
    } else {
        nx = W.hx[i];
        ny = W.hy[i];
        d = 0.0;
    }
    pen = min_d - d;
    share_r = inv_r / (inv_r + inv_b);
    share_b = inv_b / (inv_r + inv_b);
    W.rx[i] = W.rx[i] - nx * pen * share_r;
    W.ry[i] = W.ry[i] - ny * pen * share_r;
    W.bx = W.bx + nx * pen * share_b;
    W.by = W.by + ny * pen * share_b;

    rel_x = W.bvx - W.vx[i];
    rel_y = W.bvy - W.vy[i];
    vn = rel_x * nx + rel_y * ny;
    if (vn < 0.0) {
        jimp = -(1.0 + CB_REST_BALL_ROBOT) * vn / (inv_r + inv_b);
        W.vx[i] = W.vx[i] - jimp * inv_r * nx;
        W.vy[i] = W.vy[i] - jimp * inv_r * ny;
        W.bvx = W.bvx + jimp * inv_b * nx;
        W.bvy = W.bvy + jimp * inv_b * ny;
    }
    /* Dribble friction: scrub the ball's tangential velocity relative to
     * the robot, so a robot pushing the ball carries it rather than
     * letting it skid off sideways. */
    rel_x = W.bvx - W.vx[i];
    rel_y = W.bvy - W.vy[i];
    vn = rel_x * nx + rel_y * ny;
    tx = rel_x - vn * nx;
    ty = rel_y - vn * ny;
    W.bvx = W.vx[i] + vn * nx + tx * CB_DRIBBLE_TANGENT;
    W.bvy = W.vy[i] + vn * ny + ty * CB_DRIBBLE_TANGENT;

    W.last_touch_robot = i;
    W.last_touch_seat = seat_of(i);
    W.last_touch_tick = W.tick;
    emit(CB_EV_TOUCH, i, seat_of(i), 0, W.bx, W.by, 0, 0, 0, 0);
}

static void ball_post(double px, double py)
{
    double dx = W.bx - px;
    double dy = W.by - py;
    double d2 = dx * dx + dy * dy;
    double min_d = CB_BALL_R + CB_POST_R;
    double d, nx, ny, vn;
    if (d2 >= min_d * min_d) return;
    d = cb_sqrt(d2);
    if (d > 0.0) {
        nx = dx / d;
        ny = dy / d;
    } else {
        nx = 0.0;
        ny = 1.0;
        d = 0.0;
    }
    W.bx = px + nx * min_d;
    W.by = py + ny * min_d;
    vn = W.bvx * nx + W.bvy * ny;
    if (vn < 0.0) {
        W.bvx = W.bvx - (1.0 + CB_REST_BALL_POST) * vn * nx;
        W.bvy = W.bvy - (1.0 + CB_REST_BALL_POST) * vn * ny;
    }
    emit(CB_EV_POST, -1, -1, 0, px, py, 0, 0, 0, 0);
}

/* Walls for the ball. The goal mouth (|y| <= CB_GOAL_HALF_WIDTH) is open at
 * |x| = 20; everything else on the boundary is solid. The goal box beyond
 * it is closed at |x| = 22 and |y| = 3.5, but the goal test fires the
 * instant the centre crosses x = +-20, so play never actually reaches it. */
static void ball_walls(void)
{
    double r = CB_BALL_R;
    if (W.bx > CB_PITCH_X || W.bx < -CB_PITCH_X) {
        double lim = CB_GOAL_BACK - r;
        double ylim = CB_GOAL_HALF_WIDTH - r;
        if (W.bx > lim) {
            W.bx = lim;
            if (W.bvx > 0.0) W.bvx = -W.bvx * CB_REST_BALL_WALL;
            W.bvy = W.bvy * CB_BALL_WALL_TANGENT;
        } else if (W.bx < -lim) {
            W.bx = -lim;
            if (W.bvx < 0.0) W.bvx = -W.bvx * CB_REST_BALL_WALL;
            W.bvy = W.bvy * CB_BALL_WALL_TANGENT;
        }
        if (W.by > ylim) {
            W.by = ylim;
            if (W.bvy > 0.0) W.bvy = -W.bvy * CB_REST_BALL_WALL;
            W.bvx = W.bvx * CB_BALL_WALL_TANGENT;
        } else if (W.by < -ylim) {
            W.by = -ylim;
            if (W.bvy < 0.0) W.bvy = -W.bvy * CB_REST_BALL_WALL;
            W.bvx = W.bvx * CB_BALL_WALL_TANGENT;
        }
        return;
    }
    /* Inside the pitch rectangle. */
    if (W.by > CB_PITCH_Y - r) {
        W.by = CB_PITCH_Y - r;
        if (W.bvy > 0.0) W.bvy = -W.bvy * CB_REST_BALL_WALL;
        W.bvx = W.bvx * CB_BALL_WALL_TANGENT;
    } else if (W.by < -(CB_PITCH_Y - r)) {
        W.by = -(CB_PITCH_Y - r);
        if (W.bvy < 0.0) W.bvy = -W.bvy * CB_REST_BALL_WALL;
        W.bvx = W.bvx * CB_BALL_WALL_TANGENT;
    }
    if (W.by <= CB_GOAL_HALF_WIDTH && W.by >= -CB_GOAL_HALF_WIDTH)
        return; /* goal mouth: no wall here */
    if (W.bx > CB_PITCH_X - r) {
        W.bx = CB_PITCH_X - r;
        if (W.bvx > 0.0) W.bvx = -W.bvx * CB_REST_BALL_WALL;
        W.bvy = W.bvy * CB_BALL_WALL_TANGENT;
    } else if (W.bx < -(CB_PITCH_X - r)) {
        W.bx = -(CB_PITCH_X - r);
        if (W.bvx < 0.0) W.bvx = -W.bvx * CB_REST_BALL_WALL;
        W.bvy = W.bvy * CB_BALL_WALL_TANGENT;
    }
}

/* Assist: the previous DISTINCT robot of the scoring seat to touch the ball
 * within 120 ticks. The core tracks only the last toucher, so the host
 * resolves the assist from the touch event stream; here we report -1 and
 * let server/cogball/engine.py fill it in. */
static int goal_test(void)
{
    int scorer_seat;
    double speed;
    if (W.by > CB_GOAL_HALF_WIDTH || W.by < -CB_GOAL_HALF_WIDTH) return 0;
    if (W.bx >= CB_PITCH_X) {
        scorer_seat = 0; /* Azure attacks +x */
    } else if (W.bx <= -CB_PITCH_X) {
        scorer_seat = 1;
    } else {
        return 0;
    }
    W.goals[scorer_seat] += 1;
    speed = cb_sqrt(W.bvx * W.bvx + W.bvy * W.bvy);
    emit(CB_EV_GOAL, W.last_touch_robot, scorer_seat, -1, speed,
         (double)W.goals[0], (double)W.goals[1], W.bx, W.by, 0);
    kickoff(1 - scorer_seat);
    W.freeze_until = W.tick + CB_FREEZE_TICKS;
    return 1;
}

/* -- kicks ------------------------------------------------------------ */

static void do_kicks(void)
{
    int i;
    for (i = 0; i < CB_NUM_ROBOTS; i++) {
        double dx, dy, d, nx, ny, v_par, v_par_new, perp_x, perp_y, speed;
        if (g_ctl[i * 3 + 2] == 0) continue;
        if (W.cool[i] != 0) continue;
        dx = W.bx - W.rx[i];
        dy = W.by - W.ry[i];
        d = cb_sqrt(dx * dx + dy * dy);
        if (d > CB_KICK_RANGE) continue;
        if (d <= 0.0) continue;
        if ((W.hx[i] * dx + W.hy[i] * dy) / d < CB_KICK_DOT) continue;

        nx = W.hx[i];
        ny = W.hy[i];
        v_par = W.bvx * nx + W.bvy * ny;
        perp_x = W.bvx - v_par * nx;
        perp_y = W.bvy - v_par * ny;
        v_par_new = (v_par > 0.0 ? v_par : 0.0) + CB_KICK_SPEED;
        W.bvx = 0.5 * perp_x + v_par_new * nx;
        W.bvy = 0.5 * perp_y + v_par_new * ny;
        speed = cb_sqrt(W.bvx * W.bvx + W.bvy * W.bvy);
        if (speed > CB_BALL_MAX_SPEED) {
            W.bvx = W.bvx * CB_BALL_MAX_SPEED / speed;
            W.bvy = W.bvy * CB_BALL_MAX_SPEED / speed;
            speed = CB_BALL_MAX_SPEED;
        }
        W.vx[i] = W.vx[i] - nx * (CB_BALL_M * (v_par_new - v_par) / CB_ROBOT_M);
        W.vy[i] = W.vy[i] - ny * (CB_BALL_M * (v_par_new - v_par) / CB_ROBOT_M);
        W.cool[i] = CB_KICK_COOLDOWN;
        W.last_touch_robot = i;
        W.last_touch_seat = seat_of(i);
        W.last_touch_tick = W.tick;
        emit(CB_EV_KICK, i, seat_of(i), 0, W.rx[i], W.ry[i], W.bvx, W.bvy,
             W.bx, W.by);
    }
}

/* -- state export, digest, guards ------------------------------------- */

static void publish_state(void)
{
    int i;
    g_state[0] = W.bx;
    g_state[1] = W.by;
    g_state[2] = W.bvx;
    g_state[3] = W.bvy;
    for (i = 0; i < CB_NUM_ROBOTS; i++) {
        double *s = &g_state[CB_STATE_ROBOT0 + i * CB_STATE_ROBOT_STRIDE];
        s[0] = W.rx[i];
        s[1] = W.ry[i];
        s[2] = W.vx[i];
        s[3] = W.vy[i];
        s[4] = W.hx[i];
        s[5] = W.hy[i];
        s[6] = W.om[i];
        s[7] = (double)W.cool[i];
    }
    g_state[52] = (double)W.last_touch_robot;
    g_state[53] = (double)W.last_touch_seat;
    g_state[54] = (double)W.last_touch_tick;
    g_state[55] = (double)W.freeze_until;
    g_state[56] = (double)W.goals[0];
    g_state[57] = (double)W.goals[1];
    g_state[58] = (double)W.tick;
    g_state[59] = (double)W.fault;
}

static int finite_and_sane(double v)
{
    if (!(v == v)) return 0;          /* NaN */
    if (v > 1.0e9 || v < -1.0e9) return 0; /* Inf or runaway */
    return 1;
}

static void check_invariants(void)
{
    int i;
    if (!finite_and_sane(W.bx) || !finite_and_sane(W.by) ||
        !finite_and_sane(W.bvx) || !finite_and_sane(W.bvy))
        W.fault = 1;
    for (i = 0; i < CB_NUM_ROBOTS; i++) {
        if (!finite_and_sane(W.rx[i]) || !finite_and_sane(W.ry[i]) ||
            !finite_and_sane(W.vx[i]) || !finite_and_sane(W.vy[i]) ||
            !finite_and_sane(W.hx[i]) || !finite_and_sane(W.hy[i]) ||
            !finite_and_sane(W.om[i]))
            W.fault = 1;
    }
}

static void dig_bytes(unsigned int *h, const unsigned char *b, int n)
{
    int i;
    for (i = 0; i < n; i++) {
        *h = *h ^ (unsigned int)b[i];
        *h = *h * 16777619u;
    }
}

static void dig_double(unsigned int *h, double v)
{
    union {
        double d;
        unsigned char b[8];
    } u;
    u.d = v;
    dig_bytes(h, u.b, 8);
}

static void dig_int(unsigned int *h, int v)
{
    union {
        int i;
        unsigned char b[4];
    } u;
    u.i = v;
    dig_bytes(h, u.b, 4);
}

/* -- exported API ----------------------------------------------------- */

__attribute__((export_name("cogball_init")))
void cogball_init(unsigned int seed, unsigned int first_kickoff_seat)
{
    int i;
    W.bx = 0.0;
    W.by = 0.0;
    W.bvx = 0.0;
    W.bvy = 0.0;
    for (i = 0; i < CB_NUM_ROBOTS; i++) {
        W.rx[i] = 0.0;
        W.ry[i] = 0.0;
        W.vx[i] = 0.0;
        W.vy[i] = 0.0;
        W.hx[i] = 1.0;
        W.hy[i] = 0.0;
        W.om[i] = 0.0;
        W.cool[i] = 0;
    }
    W.goals[0] = 0;
    W.goals[1] = 0;
    W.tick = 0;
    W.freeze_until = 0;
    W.last_touch_robot = -1;
    W.last_touch_seat = -1;
    W.last_touch_tick = -1;
    W.fault = 0;
    for (i = 0; i < CB_NUM_ROBOTS * 3; i++) g_ctl[i] = 0;
    g_event_count = 0;
    pcg32_seed(seed);
    kickoff((int)(first_kickoff_seat & 1u));
    /* The opening kickoff is not preceded by a goal: play starts at once,
     * and the host writes its own match_start/kickoff records, so the
     * event ring starts empty. */
    W.freeze_until = 0;
    g_event_count = 0;
    publish_state();
}

__attribute__((export_name("cogball_ctl_ptr")))
unsigned char *cogball_ctl_ptr(void) { return g_ctl; }

__attribute__((export_name("cogball_step")))
void cogball_step(void)
{
    int sub, i, j;

    g_event_count = 0;

    /* Kickoff freeze: controls are forced to zero by the host, physics is
     * skipped entirely, but the tick still advances (and the host still
     * records controls and keyframes). */
    if (W.tick < W.freeze_until) {
        W.tick += 1;
        publish_state();
        return;
    }

    do_kicks();

    for (sub = 0; sub < CB_SUBSTEPS; sub++) {
        for (i = 0; i < CB_NUM_ROBOTS; i++) {
            double u_thrust = (double)(signed char)g_ctl[i * 3 + 0] / 100.0;
            double u_turn = (double)(signed char)g_ctl[i * 3 + 1] / 100.0;
            step_robot(i, u_thrust, u_turn);
        }
        step_ball();
        for (i = 0; i < CB_NUM_ROBOTS; i++) robot_walls(i);
        for (i = 0; i < CB_NUM_ROBOTS; i++)
            for (j = i + 1; j < CB_NUM_ROBOTS; j++) robot_pair(i, j);
        for (i = 0; i < CB_NUM_ROBOTS; i++) robot_ball(i);
        ball_post(CB_PITCH_X, CB_GOAL_HALF_WIDTH);
        ball_post(CB_PITCH_X, -CB_GOAL_HALF_WIDTH);
        ball_post(-CB_PITCH_X, CB_GOAL_HALF_WIDTH);
        ball_post(-CB_PITCH_X, -CB_GOAL_HALF_WIDTH);
        ball_walls();
        if (goal_test()) break; /* remaining substeps of this tick are void */
    }

    for (i = 0; i < CB_NUM_ROBOTS; i++)
        if (W.cool[i] > 0) W.cool[i] -= 1;

    W.tick += 1;
    check_invariants();
    publish_state();
}

__attribute__((export_name("cogball_tick")))
int cogball_tick(void) { return W.tick; }

__attribute__((export_name("cogball_goals")))
int cogball_goals(int seat)
{
    if (seat < 0 || seat >= CB_SEATS) return 0;
    return W.goals[seat];
}

__attribute__((export_name("cogball_frozen")))
int cogball_frozen(void) { return W.tick < W.freeze_until ? 1 : 0; }

__attribute__((export_name("cogball_fault")))
int cogball_fault(void) { return W.fault; }

__attribute__((export_name("cogball_state_ptr")))
const double *cogball_state_ptr(void) { return g_state; }

__attribute__((export_name("cogball_event_count")))
int cogball_event_count(void) { return g_event_count; }

__attribute__((export_name("cogball_event_stride")))
int cogball_event_stride(void) { return CB_EVENT_FIELDS; }

__attribute__((export_name("cogball_event_ptr")))
const double *cogball_event_ptr(void) { return g_events[0].f; }

/* Test-only placement hooks (tests/test_physics.py).
 *
 * Neither the game server nor the replay viewer ever calls these, so they
 * cannot affect a recorded episode: a replay is still reproduced by
 * cogball_init(seed, first_kickoff_seat) plus the action log alone. They
 * exist because a physics unit test has to be able to fire a ball at a wall
 * at 30 m/s, and there is no way to reach that state through kicks. */
__attribute__((export_name("cogball_debug_place_ball")))
void cogball_debug_place_ball(double x, double y, double vx, double vy)
{
    W.bx = x;
    W.by = y;
    W.bvx = vx;
    W.bvy = vy;
    publish_state();
}

__attribute__((export_name("cogball_debug_place_robot")))
void cogball_debug_place_robot(int i, double x, double y, double hx,
                               double hy, double vx, double vy)
{
    double len;
    if (i < 0 || i >= CB_NUM_ROBOTS) return;
    W.rx[i] = x;
    W.ry[i] = y;
    W.vx[i] = vx;
    W.vy[i] = vy;
    len = cb_sqrt(hx * hx + hy * hy);
    if (len > 0.0) {
        W.hx[i] = hx / len;
        W.hy[i] = hy / len;
    }
    W.om[i] = 0.0;
    W.cool[i] = 0;
    publish_state();
}

__attribute__((export_name("cogball_state_digest")))
unsigned int cogball_state_digest(void)
{
    unsigned int h = 2166136261u;
    int i;
    dig_double(&h, W.bx);
    dig_double(&h, W.by);
    dig_double(&h, W.bvx);
    dig_double(&h, W.bvy);
    for (i = 0; i < CB_NUM_ROBOTS; i++) {
        dig_double(&h, W.rx[i]);
        dig_double(&h, W.ry[i]);
        dig_double(&h, W.vx[i]);
        dig_double(&h, W.vy[i]);
        dig_double(&h, W.hx[i]);
        dig_double(&h, W.hy[i]);
        dig_double(&h, W.om[i]);
        dig_int(&h, W.cool[i]);
    }
    dig_int(&h, W.goals[0]);
    dig_int(&h, W.goals[1]);
    dig_int(&h, W.tick);
    return h;
}
