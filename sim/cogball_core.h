/* cogball deterministic physics core — public API.
 *
 * The whole world is a single static instance: six robots, one ball, two
 * goals. There is no allocation anywhere, so the module behaves identically
 * as a WASI reactor under wasmtime and as an emscripten module in a browser.
 *
 * Arithmetic discipline (tests/test_determinism.py enforces it): only
 * + - * / and sqrt on doubles, plus comparisons and integer ops. No libm,
 * no float accumulation, no -ffast-math. WebAssembly specifies exact
 * IEEE-754 results for those operations and forbids contraction, so the
 * standalone (wasmtime) and emscripten (browser / node) builds produce
 * bit-identical state — which is the guarantee the replay design rests on.
 */
#ifndef COGBALL_CORE_H
#define COGBALL_CORE_H

#include "cogball_config.h"

/* One physics event, drained by the host after every cogball_step().
 * Every field is a double so the record has no padding and no
 * endianness/alignment ambiguity across toolchains.
 *
 *   f[0] type (CB_EV_*)   f[1] robot index or -1
 *   f[2] seat or -1       f[3] aux int (assist robot / restarting seat)
 *   f[4..11] per-type payload, documented at the emit sites in the .c
 */
typedef struct {
    double f[CB_EVENT_FIELDS];
} CbEvent;

/* Reset the world for a new episode. `seed` seeds the PCG32 stream used
 * for kickoff jitter; `first_kickoff_seat` (0 or 1) restarts play. */
void cogball_init(unsigned int seed, unsigned int first_kickoff_seat);

/* The 18-byte control buffer the host writes before every step:
 * CB_NUM_ROBOTS x (int8 thrust, int8 turn, uint8 kick), robot-index order.
 * These bytes are the determinism boundary — the sim never sees an
 * un-quantised control, and they are exactly what the replay records. */
unsigned char *cogball_ctl_ptr(void);

/* Advance one tick (the four substeps and the whole resolution order). */
void cogball_step(void);

int cogball_tick(void);
int cogball_goals(int seat);
int cogball_frozen(void); /* 1 while tick < freeze_until (kickoff freeze) */
int cogball_fault(void);  /* 1 once an invariant guard tripped */

/* Packed doubles, CB_STATE_FIELDS long; layout in cogball_config.h. */
const double *cogball_state_ptr(void);

int cogball_event_count(void);
int cogball_event_stride(void); /* doubles per event record */
const double *cogball_event_ptr(void);

/* Test-only placement hooks; see the .c for why they exist and why they
 * cannot affect a recorded episode. */
void cogball_debug_place_ball(double x, double y, double vx, double vy);
void cogball_debug_place_robot(int i, double x, double y, double hx,
                               double hy, double vx, double vy);

/* FNV-1a over the raw bytes of the full dynamic state + score + tick. */
unsigned int cogball_state_digest(void);

#endif /* COGBALL_CORE_H */
