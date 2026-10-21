// Instrumented EXISTING Cogball viewer. No alternate codec or physics core.
'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('node:assert/strict');
const dist = path.resolve(process.argv[2]);
const input = fs.readFileSync(process.argv[3]);
const expected = fs.readFileSync(process.argv[4], 'utf8').trim().split('\n').map(JSON.parse);
const summary = JSON.parse(fs.readFileSync(process.argv[5], 'utf8'));
const byTick = new Map(expected.map(state => [state.tick, state]));
const watchdog = setTimeout(() => { console.error('WASM comparison timed out'); process.exit(1); }, 25000);
const Module = {
  locateFile: p => path.join(dist,p),
  onAbort: reason => {console.error(reason); process.exit(1);},
  onRuntimeInitialized: run
};
function text(ptr) {
  let end = ptr;
  while (Module.HEAPU8[end] !== 0) end++;
  return Buffer.from(Module.HEAPU8.subarray(ptr,end)).toString('utf8');
}
function state() {return JSON.parse(text(Module._cogball_proof_state()));}
function checkCurrent() {
  const actual = state();
  assert.deepEqual(actual,byTick.get(actual.tick));
  assert.equal(Module._cogball_mismatch_tick(),-1);
}
function run() {
  const ptr = Module._malloc(input.length);
  Module.HEAPU8.set(input,ptr);
  assert.equal(Module._cogball_load_replay(ptr,input.length),1);
  Module._free(ptr);
  checkCurrent();
  // Exercise the unchanged public frame + packet path, too.
  for (let i=0; i<300; i++) {
    assert.equal(Module._cogball_frame(),1);
    assert.ok(Module._cogball_packet_len()>0);
    checkCurrent();
  }
  Module._cogball_proof_reset();
  for (let i=0; i<expected.length; i++) {
    assert.deepEqual(state(),expected[i],`tick ${expected[i].tick}`);
    assert.equal(Module._cogball_mismatch_tick(),-1);
    if(i+1<expected.length) assert.equal(Module._cogball_proof_step(),1);
  }
  for(const tick of summary.seeks) {
    Module._cogball_proof_seek(tick);
    assert.deepEqual(state(),byTick.get(tick),`seek ${tick}`);
  }
  // Authored adversarial expected state: the comparator must reject it.
  const wrong = structuredClone(state());
  wrong.hash = (BigInt(wrong.hash)^1n).toString();
  assert.throws(()=>assert.deepEqual(state(),wrong),assert.AssertionError);
  clearTimeout(watchdog);
  console.log(JSON.stringify({ticks:expected.length,seeks:summary.seeks,
    existingViewerFrames:300,hashMismatch:Module._cogball_mismatch_tick(),
    comparatorRejectsWrongHash:true,wasmHeapBytes:Module.HEAPU8.length}));
  process.exit(0);
}
const bundle = path.join(dist,'cogball_replay.js');
new Function('Module','require','__filename','__dirname',fs.readFileSync(bundle,'utf8'))(
  Module,require,bundle,dist);
