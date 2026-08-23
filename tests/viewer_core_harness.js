#!/usr/bin/env node
// Headless verification harness for the cogball viewer core (no raylib).
//
// Usage: node viewer_core_harness.js <build/viewer_core.js> <replay.json>
//
// Loads the replay exactly like viewer/static_replay.js does (JSON parsed in
// JS, controls_b64 decoded, bytes copied into the wasm heap, seed and
// first_kickoff_seat passed down), then:
//
//   * walks the whole action log and records the state digest at every
//     30-tick keyframe -- this is the cross-build half of the determinism
//     gate: the emscripten build under node must agree with the standalone
//     build under wasmtime at every one of them;
//   * exercises the transport (cadence, pause, seek-to-mid, seek-to-end);
//   * proves malformed inputs are rejected, both the JS-side document
//     checks and the C-side action-log length check.
//
// Prints one JSON object for tests/test_viewer.py and
// tests/test_determinism.py to assert on. Exits non-zero on any failure.
"use strict";

const fs = require("fs");
const path = require("path");

const BYTES_PER_TICK = 18;
const PROTOCOL = "cogball/v1";

const [, , coreJsPath, replayPath] = process.argv;
if (!coreJsPath || !replayPath) {
  console.error("usage: viewer_core_harness.js <viewer_core.js> <replay.json>");
  process.exit(2);
}

function decodeControls(doc) {
  const bytes = Buffer.from(doc.controls_b64, "base64");
  if (bytes.length !== doc.tick_count * BYTES_PER_TICK) {
    throw new Error(`controls are ${bytes.length} bytes, expected ` +
      `${doc.tick_count * BYTES_PER_TICK}`);
  }
  return new Uint8Array(bytes);
}

// Mirrors static_replay.js parseReplay: the shell's document validation is
// the thing under test here, so it is duplicated rather than imported.
function parseReplay(text) {
  const doc = JSON.parse(text);
  if (!doc || doc.protocol !== PROTOCOL) {
    throw new Error("bad protocol: " + (doc && doc.protocol));
  }
  if (!Number.isInteger(doc.tick_count) || doc.tick_count <= 0) {
    throw new Error("bad tick_count: " + doc.tick_count);
  }
  if (!Number.isInteger(doc.seed)) {
    throw new Error("seed is not an integer: " + doc.seed);
  }
  doc._controls = decodeControls(doc);
  return doc;
}

const text = fs.readFileSync(replayPath, "utf-8");
const replay = parseReplay(text);
const createViewerCore = require(path.resolve(coreJsPath));

function rejects(fn) {
  try {
    fn();
    return false;
  } catch (e) {
    return true;
  }
}

function documentRejections() {
  const good = JSON.parse(text);
  const cases = {};
  cases.badProtocol = rejects(() => parseReplay(
    JSON.stringify(Object.assign({}, good, { protocol: "cogball/v0" }))));
  cases.badBase64Length = rejects(() => parseReplay(
    JSON.stringify(Object.assign({}, good, {
      controls_b64: Buffer.from(new Uint8Array(BYTES_PER_TICK + 1))
        .toString("base64")
    }))));
  cases.truncatedJson = rejects(() => parseReplay(text.slice(0, text.length - 12)));
  cases.tickCountMismatch = rejects(() => parseReplay(
    JSON.stringify(Object.assign({}, good, {
      tick_count: good.tick_count + 1
    }))));
  return cases;
}

function run(M) {
  const call = (name, ret, args = [], vals = []) => M.ccall(name, ret, args, vals);

  // C-side: an action log whose length is not a whole number of ticks, and
  // an empty one, must both be refused before anything is simulated.
  const tryLoad = (len) => {
    const p = M._malloc(Math.max(1, len));
    const r = call("viewer_load", "number",
      ["number", "number", "number", "number"], [p, len, 1, 0]);
    M._free(p);
    return r;
  };
  const malformed = Object.assign(documentRejections(), {
    raggedLog: tryLoad(BYTES_PER_TICK + 1),
    emptyLog: tryLoad(0)
  });

  const bytes = replay._controls;
  const ptr = M._malloc(bytes.length);
  M.HEAPU8.set(bytes, ptr);
  const total = call("viewer_load", "number",
    ["number", "number", "number", "number"],
    [ptr, bytes.length, replay.seed >>> 0, replay.first_kickoff_seat | 0]);

  // Walk the whole log, sampling the digest at every 30-tick keyframe.
  const digests = [];
  digests.push([0, call("viewer_state_digest", "number") >>> 0]);
  while (call("viewer_tick", "number") < total) {
    const stepped = call("viewer_step", "number", ["number"], [30]);
    if (stepped === 0) break;
    const t = call("viewer_tick", "number");
    // t === total is the end state, not a keyframe: the recording stops
    // writing keyframes at the last tick it played. It is reported
    // separately as endDigest.
    if (t % 30 === 0 && t < total) {
      digests.push([t, call("viewer_state_digest", "number") >>> 0]);
    }
  }
  const endDigest = call("viewer_state_digest", "number") >>> 0;

  // Transport: at 1x one tick per 1000/30 ms of wall time, independent of
  // callback count; a single 5000 ms callback clamps to 100 ms (no burst).
  const mid = Math.floor(total / 2);
  call("viewer_seek", null, ["number"], [mid]);
  const midTick = call("viewer_tick", "number");
  const midDigest = call("viewer_state_digest", "number") >>> 0;
  call("viewer_set_speed", null, ["number"], [100]);
  call("viewer_set_playing", null, ["number"], [1]);
  const dt16a = call("viewer_advance", "number", ["number"], [16]);
  const dt16b = call("viewer_advance", "number", ["number"], [16]);
  const dt16c = call("viewer_advance", "number", ["number"], [16]);
  const dtClamped = call("viewer_advance", "number", ["number"], [5000]);
  call("viewer_set_playing", null, ["number"], [0]);
  const pausedTicks = call("viewer_advance", "number", ["number"], [1000]);
  call("viewer_set_speed", null, ["number"], [6400]);
  call("viewer_set_playing", null, ["number"], [1]);
  const fastTicks = call("viewer_advance", "number", ["number"], [100]);

  call("viewer_seek", null, ["number"], [total]);
  const endTick = call("viewer_tick", "number");
  const playingAtEnd = call("viewer_playing", "number");
  call("viewer_set_playing", null, ["number"], [1]);
  const playAtEndRefused = call("viewer_playing", "number") === 0 ? 1 : 0;
  const seekEndDigest = call("viewer_state_digest", "number") >>> 0;

  console.log(JSON.stringify({
    malformed,
    total,
    headerTickCount: replay.tick_count,
    digests,
    endDigest,
    seekEndDigest,
    midTick,
    midDigest,
    endTick,
    playingAtEnd,
    playAtEndRefused,
    dt16a, dt16b, dt16c, dtClamped, pausedTicks, fastTicks,
    goals: [call("viewer_goals", "number", ["number"], [0]),
            call("viewer_goals", "number", ["number"], [1])],
    winner: call("viewer_winner", "number"),
    done: call("viewer_done", "number")
  }));
}

createViewerCore().then(run).catch((e) => {
  console.error("harness failed:", e);
  process.exit(1);
});
