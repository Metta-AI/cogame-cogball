/* cogball replay viewer: re-simulates a recorded match in the browser from
 * the SAME physics core the game server ran, and draws it with raylib.
 *
 * Built twice by sim/build_viewer.sh:
 *   - with -DCOGBALL_RENDER (raylib + emscripten main loop)
 *       -> viewer/dist/cogball_viewer.{js,wasm}     browser bundle
 *   - without it (headless core, ENVIRONMENT=node, --no-entry)
 *       -> build/viewer_core.{js,wasm}              node verification
 *
 * The core API (viewer_load / viewer_seek / viewer_advance / ...) is
 * identical in both builds; only the raylib loop is render-only.  That is
 * what lets tests/test_determinism.py and tests/test_viewer.py prove the
 * re-simulation under node, with no pixels involved.
 *
 * The replay is UTF-8 JSON (server/cogball/replay.py is the authority); the
 * JSON is parsed in JavaScript and only the decoded `controls_b64` bytes,
 * the seed and the first kickoff seat are handed down here.  C never parses
 * JSON: tick_count == len / 18 by construction.
 *
 * Determinism: viewer_seek() rebuilds the world through the exact
 * cogball_init() path the server host uses and replays the RECORDED control
 * bytes from tick 0.  The control layer is never re-implemented here — the
 * bytes are the ground truth — so the viewer cannot drift from the server
 * for any reason other than the physics core itself changing, which
 * tests/test_determinism.py forbids.
 */

#include "cogball_core.h"

#ifdef COGBALL_RENDER
#include <emscripten.h>
#include "raylib.h"
#endif

#define VIEWER_BYTES_PER_TICK (CB_NUM_ROBOTS * 3) /* 18 */

/* Playback: 1x is real time, 30 sim ticks per second. Speeds are PERCENT
 * (100 = 1x, 25 = the slow-motion goal replay, 6400 = 64x) because the
 * instant-replay feature needs a fractional rate and the transport is the
 * only place that knows about it. */
#define VIEWER_TICK_MS (1000.0 / 30.0)
#define VIEWER_MAX_DT_MS 100.0 /* a backgrounded tab must not burst on return */
#define VIEWER_PHASE_STEPS 16  /* sub-tick interpolation granularity */

#define TRAIL_LEN 45 /* ball trail: the last 1.5 s of ball positions */

static const unsigned char *g_body = 0; /* control log, in JS-owned heap */
static int g_total_ticks = 0;
static int g_tick = 0;
static int g_playing = 0;
static int g_speed = 100; /* percent */
static double g_time_acc = 0.0;
static int g_phase = VIEWER_PHASE_STEPS;
static unsigned int g_seed = 0;
static int g_kickoff_seat = 0;
static int g_loaded = 0;

/* Interpolation: the state one tick back, so the renderer can draw between
 * ticks instead of stepping. */
static double g_prev_bx, g_prev_by;
static double g_prev_rx[CB_NUM_ROBOTS], g_prev_ry[CB_NUM_ROBOTS];
static double g_prev_hx[CB_NUM_ROBOTS], g_prev_hy[CB_NUM_ROBOTS];

static double g_trail_x[TRAIL_LEN], g_trail_y[TRAIL_LEN];
static int g_trail_seat[TRAIL_LEN];
static int g_trail_n = 0;

static void snapshot_prev(void)
{
    const double *s = cogball_state_ptr();
    int i;
    g_prev_bx = s[0];
    g_prev_by = s[1];
    for (i = 0; i < CB_NUM_ROBOTS; i++) {
        const double *r = &s[CB_STATE_ROBOT0 + i * CB_STATE_ROBOT_STRIDE];
        g_prev_rx[i] = r[0];
        g_prev_ry[i] = r[1];
        g_prev_hx[i] = r[4];
        g_prev_hy[i] = r[5];
    }
}

#ifdef COGBALL_RENDER
static void fx_on_events(void);
static void heat_sample(void);
static void reset_fx(void);
#endif

static void push_trail(void)
{
    const double *s = cogball_state_ptr();
    int i;
    if (g_trail_n < TRAIL_LEN) {
        g_trail_x[g_trail_n] = s[0];
        g_trail_y[g_trail_n] = s[1];
        g_trail_seat[g_trail_n] = (int)s[53];
        g_trail_n++;
        return;
    }
    for (i = 1; i < TRAIL_LEN; i++) {
        g_trail_x[i - 1] = g_trail_x[i];
        g_trail_y[i - 1] = g_trail_y[i];
        g_trail_seat[i - 1] = g_trail_seat[i];
    }
    g_trail_x[TRAIL_LEN - 1] = s[0];
    g_trail_y[TRAIL_LEN - 1] = s[1];
    g_trail_seat[TRAIL_LEN - 1] = (int)s[53];
}

static void sim_fresh(void)
{
    cogball_init(g_seed, (unsigned int)g_kickoff_seat);
    g_tick = 0;
    g_trail_n = 0;
    snapshot_prev();
#ifdef COGBALL_RENDER
    reset_fx();
#endif
}

static void feed_and_step(void)
{
    unsigned char *ctl = cogball_ctl_ptr();
    const unsigned char *a =
        g_body + (unsigned long)g_tick * VIEWER_BYTES_PER_TICK;
    int i;
    snapshot_prev();
    for (i = 0; i < VIEWER_BYTES_PER_TICK; i++) ctl[i] = a[i];
    cogball_step();
    g_tick++;
    push_trail();
#ifdef COGBALL_RENDER
    fx_on_events();
    heat_sample();
#endif
}

/* -- exported transport ------------------------------------------------ */

int viewer_load(const unsigned char *controls, int len, unsigned int seed,
                int first_kickoff_seat)
{
    if (controls == 0 || len < 0) return -1;
    if (len % VIEWER_BYTES_PER_TICK != 0) return -1;
    if (len == 0) return -1;
    g_body = controls;
    g_total_ticks = len / VIEWER_BYTES_PER_TICK;
    g_seed = seed;
    g_kickoff_seat = first_kickoff_seat ? 1 : 0;
    g_playing = 0;
    g_time_acc = 0.0;
    g_phase = VIEWER_PHASE_STEPS;
    sim_fresh();
    g_loaded = 1;
    return g_total_ticks;
}

void viewer_seek(int tick)
{
    if (!g_loaded) return;
    if (tick < 0) tick = 0;
    if (tick > g_total_ticks) tick = g_total_ticks;
    sim_fresh();
    while (g_tick < tick) feed_and_step();
    g_time_acc = 0.0;
    g_phase = VIEWER_PHASE_STEPS;
    if (g_tick >= g_total_ticks) g_playing = 0;
}

/* Advance exactly n ticks, ignoring playback timing. The verification
 * harness (tests/viewer_core_harness.js) walks the whole replay with this
 * and compares the digest at every 30-tick keyframe against the recording;
 * seeking to each keyframe instead would be quadratic. */
int viewer_step(int n)
{
    int stepped = 0;
    if (!g_loaded) return 0;
    while (stepped < n && g_tick < g_total_ticks) {
        feed_and_step();
        stepped++;
    }
    g_phase = VIEWER_PHASE_STEPS;
    return stepped;
}

int viewer_advance(double dt_ms)
{
    int stepped = 0;
    if (!g_loaded || !g_playing) return 0;
    if (dt_ms < 0.0) dt_ms = 0.0;
    if (dt_ms > VIEWER_MAX_DT_MS) dt_ms = VIEWER_MAX_DT_MS;
    g_time_acc += dt_ms * (double)g_speed / 100.0;
    while (g_time_acc >= VIEWER_TICK_MS - 1e-6) {
        g_time_acc -= VIEWER_TICK_MS;
        if (g_time_acc < 0.0) g_time_acc = 0.0;
        if (g_tick >= g_total_ticks) {
            g_playing = 0;
            g_time_acc = 0.0;
            break;
        }
        feed_and_step();
        stepped++;
        if (g_tick >= g_total_ticks) {
            g_playing = 0;
            g_time_acc = 0.0;
            break;
        }
    }
    if (g_tick >= g_total_ticks || stepped > 1) {
        g_phase = VIEWER_PHASE_STEPS; /* render exactly at-tick */
    } else {
        int p = (int)(g_time_acc * VIEWER_PHASE_STEPS / VIEWER_TICK_MS);
        if (p < 0) p = 0;
        if (p >= VIEWER_PHASE_STEPS) p = VIEWER_PHASE_STEPS - 1;
        if (stepped == 1 || g_phase != VIEWER_PHASE_STEPS) g_phase = p;
    }
    return stepped;
}

int viewer_advance_frame(void) { return viewer_advance(1000.0 / 60.0); }

int viewer_render_phase(void) { return g_phase; }

int viewer_tick(void) { return g_tick; }

int viewer_total_ticks(void) { return g_total_ticks; }

void viewer_set_speed(int speed_percent)
{
    if (speed_percent >= 1 && speed_percent <= 100000) g_speed = speed_percent;
}

int viewer_get_speed(void) { return g_speed; }

void viewer_set_playing(int playing)
{
    if (!g_loaded) return;
    if (playing && g_tick >= g_total_ticks) return; /* no silent loop */
    g_playing = playing ? 1 : 0;
}

int viewer_playing(void) { return g_playing; }

int viewer_done(void)
{
    return (g_loaded && g_tick >= g_total_ticks) ? 1 : 0;
}

int viewer_goals(int seat) { return cogball_goals(seat); }

int viewer_winner(void)
{
    int a = cogball_goals(0);
    int b = cogball_goals(1);
    if (a > b) return 0;
    if (b > a) return 1;
    return -1;
}

unsigned int viewer_state_digest(void) { return cogball_state_digest(); }

/* ===================================================================== */
/* Renderer                                                              */
/* ===================================================================== */
#ifdef COGBALL_RENDER

#define SCREEN_W 1008
#define SCREEN_H 600
#define VIEW_SCALE 21.4

#define MAX_RINGS 24
#define MAX_SPARKS 240

typedef struct {
    double x, y;
    int age;
    int seat;
} Ring;

typedef struct {
    double x, y, vx, vy;
    int age;
    int seat;
} Spark;

static Ring g_rings[MAX_RINGS];
static int g_ring_n = 0;
static Spark g_sparks[MAX_SPARKS];
static int g_spark_n = 0;
static int g_goal_flash = 0;
static int g_goal_seat = 0;
static RenderTexture2D g_heat;
static int g_heat_ready = 0;
static int g_heat_clear = 1;
static int g_heat_pending = 0;
#define HEAT_CAP 16384
static double g_heat_x[HEAT_CAP];
static double g_heat_y[HEAT_CAP];
static unsigned char g_heat_r[HEAT_CAP];
static int g_heat_on = 1;
static unsigned int g_rng = 0x2545F491u;

/* Local xorshift for firework spread: cosmetic only, never touches the
 * physics stream (cogball_core.c owns the only deterministic RNG). */
static double frand(void)
{
    g_rng ^= g_rng << 13;
    g_rng ^= g_rng >> 17;
    g_rng ^= g_rng << 5;
    return (double)g_rng / 4294967296.0;
}

static float sx_of(double wx) { return (float)(SCREEN_W * 0.5 + wx * VIEW_SCALE); }
static float sy_of(double wy) { return (float)(SCREEN_H * 0.5 - wy * VIEW_SCALE); }
static float px_of(double metres) { return (float)(metres * VIEW_SCALE); }

static Color robot_colour(int robot)
{
    /* Azure 190/202/214, Magenta 330/342/354 (docs/plans design note). */
    static const int hues[CB_NUM_ROBOTS] = {190, 202, 214, 330, 342, 354};
    return ColorFromHSV((float)hues[robot], 0.62f, 0.95f);
}

static Color seat_colour(int seat)
{
    return seat == 0 ? ColorFromHSV(202.0f, 0.70f, 0.95f)
                     : ColorFromHSV(342.0f, 0.70f, 0.95f);
}

static Color fade_colour(Color c, float alpha)
{
    c.a = (unsigned char)(alpha * 255.0f);
    return c;
}

static void reset_fx(void)
{
    g_ring_n = 0;
    g_spark_n = 0;
    g_goal_flash = 0;
    g_heat_clear = 1;
    g_heat_pending = 0;
}

static void add_ring(double x, double y, int seat)
{
    if (g_ring_n >= MAX_RINGS) return;
    g_rings[g_ring_n].x = x;
    g_rings[g_ring_n].y = y;
    g_rings[g_ring_n].age = 0;
    g_rings[g_ring_n].seat = seat;
    g_ring_n++;
}

static void add_fireworks(double x, double y, int seat)
{
    int i;
    for (i = 0; i < 120 && g_spark_n < MAX_SPARKS; i++) {
        double dx, dy, len, speed;
        do { /* rejection-sample a direction: no trig anywhere in this file */
            dx = frand() * 2.0 - 1.0;
            dy = frand() * 2.0 - 1.0;
            len = dx * dx + dy * dy;
        } while (len > 1.0 || len < 0.0001);
        len = __builtin_sqrt(len);
        speed = 0.18 + frand() * 0.34;
        g_sparks[g_spark_n].x = x;
        g_sparks[g_spark_n].y = y;
        g_sparks[g_spark_n].vx = dx / len * speed;
        g_sparks[g_spark_n].vy = dy / len * speed;
        g_sparks[g_spark_n].age = 0;
        g_sparks[g_spark_n].seat = seat;
        g_spark_n++;
    }
}

static void fx_on_events(void)
{
    const double *ev = cogball_event_ptr();
    int stride = cogball_event_stride();
    int n = cogball_event_count();
    int i;
    for (i = 0; i < n; i++) {
        const double *e = &ev[i * stride];
        int type = (int)e[0];
        if (type == (int)CB_EV_KICK) {
            add_ring(e[8], e[9], (int)e[2]);
        } else if (type == (int)CB_EV_GOAL) {
            g_goal_flash = 45;
            g_goal_seat = (int)e[2];
            add_fireworks(e[8], e[9], (int)e[2]);
        }
    }
}

static void heat_sample(void)
{
    const double *s = cogball_state_ptr();
    int i;
    if (!g_heat_on) return;
    if (g_tick % 3 != 0) return;
    for (i = 0; i < CB_NUM_ROBOTS; i++) {
        const double *r = &s[CB_STATE_ROBOT0 + i * CB_STATE_ROBOT_STRIDE];
        if (g_heat_pending >= HEAT_CAP) return;
        g_heat_x[g_heat_pending] = r[0];
        g_heat_y[g_heat_pending] = r[1];
        g_heat_r[g_heat_pending] = (unsigned char)i;
        g_heat_pending++;
    }
}

void viewer_set_heat(int on)
{
    g_heat_on = on ? 1 : 0;
    if (!g_heat_on) {
        g_heat_clear = 1;
        g_heat_pending = 0;
    }
}

static void flush_heat(void)
{
    int i;
    if (!g_heat_ready) return;
    if (!g_heat_clear && g_heat_pending == 0) return;
    BeginTextureMode(g_heat);
    if (g_heat_clear) {
        ClearBackground(BLANK);
        g_heat_clear = 0;
    }
    for (i = 0; i < g_heat_pending; i++) {
        Color c = robot_colour(g_heat_r[i]);
        c.a = 16;
        DrawCircle((int)sx_of(g_heat_x[i]), (int)sy_of(g_heat_y[i]),
                   3.0f, c);
    }
    EndTextureMode();
    g_heat_pending = 0;
}

static void draw_pitch(void)
{
    const Color turf_a = (Color){26, 74, 48, 255};
    const Color turf_b = (Color){22, 66, 42, 255};
    const Color paint = (Color){225, 240, 235, 190};
    double x;
    int band = 0;
    float stroke = px_of(0.12);

    /* mown bands */
    for (x = -CB_PITCH_X; x < CB_PITCH_X - 0.0001; x += 2.5, band++) {
        DrawRectangle((int)sx_of(x), (int)sy_of(CB_PITCH_Y),
                      (int)px_of(2.5) + 1, (int)px_of(2.0 * CB_PITCH_Y),
                      band % 2 ? turf_b : turf_a);
    }

    /* touchlines + goal lines */
    DrawRectangleLinesEx((Rectangle){sx_of(-CB_PITCH_X), sy_of(CB_PITCH_Y),
                                     px_of(2.0 * CB_PITCH_X),
                                     px_of(2.0 * CB_PITCH_Y)},
                         stroke, paint);
    /* halfway line + centre circle + spot */
    DrawLineEx((Vector2){sx_of(0), sy_of(CB_PITCH_Y)},
               (Vector2){sx_of(0), sy_of(-CB_PITCH_Y)}, stroke, paint);
    DrawRing((Vector2){sx_of(0), sy_of(0)}, px_of(3.0) - stroke * 0.5f,
             px_of(3.0) + stroke * 0.5f, 0.0f, 360.0f, 64, paint);
    DrawCircle((int)sx_of(0), (int)sy_of(0), px_of(0.16), paint);

    /* penalty areas and goal arcs, both ends */
    DrawRectangleLinesEx(
        (Rectangle){sx_of(-CB_PITCH_X), sy_of(CB_PENALTY_Y),
                    px_of(CB_PITCH_X - CB_PENALTY_X), px_of(2.0 * CB_PENALTY_Y)},
        stroke, paint);
    DrawRectangleLinesEx(
        (Rectangle){sx_of(CB_PENALTY_X), sy_of(CB_PENALTY_Y),
                    px_of(CB_PITCH_X - CB_PENALTY_X), px_of(2.0 * CB_PENALTY_Y)},
        stroke, paint);
    DrawRing((Vector2){sx_of(-CB_PITCH_X), sy_of(0)}, px_of(3.0) - stroke * 0.5f,
             px_of(3.0) + stroke * 0.5f, -70.0f, 70.0f, 32, paint);
    DrawRing((Vector2){sx_of(CB_PITCH_X), sy_of(0)}, px_of(3.0) - stroke * 0.5f,
             px_of(3.0) + stroke * 0.5f, 110.0f, 250.0f, 32, paint);

    /* goal nets: hatched quads with a little depth */
    {
        int side, i;
        for (side = 0; side < 2; side++) {
            double gx = side ? CB_PITCH_X : -CB_GOAL_BACK;
            Color net = (Color){200, 220, 230, 40};
            DrawRectangle((int)sx_of(gx), (int)sy_of(CB_GOAL_HALF_WIDTH),
                          (int)px_of(CB_GOAL_BACK - CB_PITCH_X),
                          (int)px_of(2.0 * CB_GOAL_HALF_WIDTH),
                          (Color){12, 26, 24, 210});
            for (i = 0; i <= 8; i++) {
                double t = gx + (CB_GOAL_BACK - CB_PITCH_X) * i / 8.0;
                DrawLineEx((Vector2){sx_of(t), sy_of(CB_GOAL_HALF_WIDTH)},
                           (Vector2){sx_of(t), sy_of(-CB_GOAL_HALF_WIDTH)},
                           1.0f, net);
            }
            for (i = 0; i <= 7; i++) {
                double ty = -CB_GOAL_HALF_WIDTH
                            + 2.0 * CB_GOAL_HALF_WIDTH * i / 7.0;
                DrawLineEx((Vector2){sx_of(gx), sy_of(ty)},
                           (Vector2){sx_of(gx + (CB_GOAL_BACK - CB_PITCH_X)),
                                     sy_of(ty)},
                           1.0f, net);
            }
        }
        /* posts */
        DrawCircle((int)sx_of(-CB_PITCH_X), (int)sy_of(CB_GOAL_HALF_WIDTH),
                   px_of(CB_POST_R) + 1.5f, RAYWHITE);
        DrawCircle((int)sx_of(-CB_PITCH_X), (int)sy_of(-CB_GOAL_HALF_WIDTH),
                   px_of(CB_POST_R) + 1.5f, RAYWHITE);
        DrawCircle((int)sx_of(CB_PITCH_X), (int)sy_of(CB_GOAL_HALF_WIDTH),
                   px_of(CB_POST_R) + 1.5f, RAYWHITE);
        DrawCircle((int)sx_of(CB_PITCH_X), (int)sy_of(-CB_GOAL_HALF_WIDTH),
                   px_of(CB_POST_R) + 1.5f, RAYWHITE);
    }
}

static void draw_trail(void)
{
    int i;
    for (i = 1; i < g_trail_n; i++) {
        float t = (float)i / (float)g_trail_n;
        Color c = g_trail_seat[i] >= 0 ? seat_colour(g_trail_seat[i])
                                       : (Color){220, 230, 235, 255};
        DrawLineEx((Vector2){sx_of(g_trail_x[i - 1]), sy_of(g_trail_y[i - 1])},
                   (Vector2){sx_of(g_trail_x[i]), sy_of(g_trail_y[i])},
                   1.0f + 5.0f * t, fade_colour(c, 0.10f + 0.45f * t));
    }
}

static void draw_robot(int i, double x, double y, double hx, double hy)
{
    static const char *ids[CB_NUM_ROBOTS] = {"AZ-1", "AZ-2", "AZ-3",
                                             "MG-1", "MG-2", "MG-3"};
    Color base = robot_colour(i);
    float r = px_of(CB_ROBOT_R);
    float cx = sx_of(x), cy = sy_of(y);
    Vector2 nose = (Vector2){sx_of(x + hx * CB_ROBOT_R * 1.35),
                             sy_of(y + hy * CB_ROBOT_R * 1.35)};
    Vector2 left = (Vector2){sx_of(x - hy * CB_ROBOT_R * 0.55),
                             sy_of(y + hx * CB_ROBOT_R * 0.55)};
    Vector2 right = (Vector2){sx_of(x + hy * CB_ROBOT_R * 0.55),
                              sy_of(y - hx * CB_ROBOT_R * 0.55)};
    int w;

    DrawCircle((int)(cx + 2.0f), (int)(cy + 4.0f), r, (Color){0, 0, 0, 70});
    DrawCircleV((Vector2){cx, cy}, r, (Color){18, 26, 30, 255});
    DrawCircleV((Vector2){cx, cy}, r * 0.82f, base);
    DrawCircleV((Vector2){cx - r * 0.16f, cy - r * 0.18f}, r * 0.52f,
                fade_colour(WHITE, 0.16f));
    DrawRing((Vector2){cx, cy}, r * 0.82f, r * 0.98f, 0.0f, 360.0f, 32,
             fade_colour(WHITE, 0.55f));
    /* Both windings: raylib culls a clockwise 2D triangle, and the
     * screen-space y flip makes the correct order depend on the heading. */
    DrawTriangle(nose, left, right, fade_colour(RAYWHITE, 0.92f));
    DrawTriangle(nose, right, left, fade_colour(RAYWHITE, 0.92f));

    w = MeasureText(ids[i], 11);
    DrawText(ids[i], (int)(cx - w * 0.5f), (int)(cy + r + 3.0f), 11,
             fade_colour(base, 0.95f));
}

static void draw_ball(double x, double y)
{
    float cx = sx_of(x), cy = sy_of(y);
    float r = px_of(CB_BALL_R);
    DrawCircle((int)(cx + 1.5f), (int)(cy + 3.0f), r, (Color){0, 0, 0, 80});
    DrawCircleV((Vector2){cx, cy}, r, (Color){245, 248, 250, 255});
    DrawCircleV((Vector2){cx + r * 0.22f, cy + r * 0.24f}, r * 0.68f,
                (Color){206, 214, 220, 255});
    DrawCircleV((Vector2){cx - r * 0.24f, cy - r * 0.26f}, r * 0.40f,
                (Color){255, 255, 255, 235});
    /* rolling seam: a short arc whose phase advances with the tick */
    DrawRing((Vector2){cx, cy}, r * 0.42f, r * 0.60f,
             (float)((g_tick * 9) % 360), (float)((g_tick * 9) % 360 + 150.0),
             18, (Color){60, 70, 78, 200});
}

static void draw_fx(void)
{
    int i, j;
    for (i = 0; i < g_ring_n;) {
        Ring *ring = &g_rings[i];
        float t = (float)ring->age / 12.0f;
        if (ring->age >= 12) {
            g_rings[i] = g_rings[--g_ring_n];
            continue;
        }
        {
            float rr = px_of(0.35 + 1.25 * t);
            DrawRing((Vector2){sx_of(ring->x), sy_of(ring->y)}, rr - 2.0f,
                     rr + 1.0f, 0.0f, 360.0f, 32,
                     fade_colour(seat_colour(ring->seat), 0.65f * (1.0f - t)));
        }
        ring->age++;
        i++;
    }
    for (j = 0; j < g_spark_n;) {
        Spark *s = &g_sparks[j];
        float t = (float)s->age / 45.0f;
        if (s->age >= 45) {
            g_sparks[j] = g_sparks[--g_spark_n];
            continue;
        }
        DrawCircleV((Vector2){sx_of(s->x), sy_of(s->y)}, 2.6f * (1.0f - t),
                    fade_colour(seat_colour(s->seat), 1.0f - t));
        s->x += s->vx;
        s->y += s->vy;
        s->vy -= 0.012;
        s->age++;
        j++;
    }
    if (g_goal_flash > 0) {
        float a = (float)g_goal_flash / 45.0f;
        DrawRectangle(0, 0, SCREEN_W, SCREEN_H,
                      fade_colour(seat_colour(g_goal_seat), 0.30f * a));
        g_goal_flash--;
    }
}

static void draw_vignette(void)
{
    int i;
    for (i = 0; i < 26; i++) {
        unsigned char a = (unsigned char)(70 - i * 2);
        DrawRectangleLinesEx((Rectangle){(float)i, (float)i,
                                         (float)(SCREEN_W - 2 * i),
                                         (float)(SCREEN_H - 2 * i)},
                             1.0f, (Color){5, 12, 12, a});
    }
}

static void frame(void)
{
    static double last_now = -1.0;
    double now = emscripten_get_now();
    double dt_ms = (last_now < 0.0) ? 0.0 : now - last_now;
    const double *s;
    double f;
    int i;

    last_now = now;
    if (!g_loaded) {
        BeginDrawing();
        ClearBackground((Color){11, 20, 20, 255});
        EndDrawing();
        return;
    }
    viewer_advance(dt_ms);
    flush_heat();

    s = cogball_state_ptr();
    f = (double)g_phase / (double)VIEWER_PHASE_STEPS;

    BeginDrawing();
    ClearBackground((Color){11, 20, 20, 255});
    draw_pitch();
    if (g_heat_on && g_heat_ready) {
        /* Render textures come out vertically flipped: a negative source
         * height is raylib's documented way to draw one upright. */
        DrawTextureRec(g_heat.texture,
                       (Rectangle){0.0f, 0.0f, (float)g_heat.texture.width,
                                   -(float)g_heat.texture.height},
                       (Vector2){0.0f, 0.0f}, WHITE);
    }
    draw_trail();
    for (i = 0; i < CB_NUM_ROBOTS; i++) {
        const double *r = &s[CB_STATE_ROBOT0 + i * CB_STATE_ROBOT_STRIDE];
        draw_robot(i,
                   g_prev_rx[i] + (r[0] - g_prev_rx[i]) * f,
                   g_prev_ry[i] + (r[1] - g_prev_ry[i]) * f,
                   g_prev_hx[i] + (r[4] - g_prev_hx[i]) * f,
                   g_prev_hy[i] + (r[5] - g_prev_hy[i]) * f);
    }
    draw_ball(g_prev_bx + (s[0] - g_prev_bx) * f,
              g_prev_by + (s[1] - g_prev_by) * f);
    draw_fx();
    draw_vignette();
    EndDrawing();
}

int main(void)
{
    InitWindow(SCREEN_W, SCREEN_H, "cogball replay");
    g_heat = LoadRenderTexture(SCREEN_W, SCREEN_H);
    g_heat_ready = (g_heat.id != 0) ? 1 : 0;
    /* 0 fps == requestAnimationFrame; main returns and the runtime stays
     * alive (EXIT_RUNTIME=0) for the viewer_* exports. */
    emscripten_set_main_loop(frame, 0, 0);
    return 0;
}

#endif /* COGBALL_RENDER */
