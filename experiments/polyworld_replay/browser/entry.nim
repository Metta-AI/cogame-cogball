## Actual Polyworld WebGL2 renderer over the original Cogball replay runtime.
## Only the separately sanitized replay is admitted to this experiment bundle.
import std/[json, os, strutils]
import opengl, flatty, vmath
import polyworld/shapes
import cogball/[sim, replays, replay_runtime]
import ../snapshot, ../scene

{.emit: """
#include <emscripten.h>
#include <emscripten/html5.h>
static int cogball_context(void) {
  EmscriptenWebGLContextAttributes attrs;
  emscripten_webgl_init_context_attributes(&attrs);
  attrs.majorVersion = 2;
  attrs.preserveDrawingBuffer = EM_TRUE;
  attrs.antialias = EM_FALSE;
  int context = emscripten_webgl_create_context("#canvas", &attrs);
  if (context <= 0) return 0;
  return emscripten_webgl_make_context_current(context) == EMSCRIPTEN_RESULT_SUCCESS;
}
""".}
proc createContext(): cint {.importc:"cogball_context", nodecl.}
var runtime = initReplayRuntime(parseReplayBytes(readFile("/public.bitreplay")),true,false)
runtime.sim = initSimServer(runtime.config)
runtime.sim.gameEventLoggingEnabled = false
runtime.player = initReplayPlayer(runtime.player.data)
runtime.player.mismatchQuit = true
doAssert createContext() == 1
var renderer = initShapeRenderer()
var output: string
proc state(): cstring {.exportc:"cogball_browser_state", cdecl.} =
  output = $proofJson(runtime.sim)
  output.cstring
proc step(): cint {.exportc:"cogball_browser_step", cdecl.} =
  if runtime.sim.tickCount >= runtime.player.replayMaxTick(): return 0
  runtime.player.stepReplay(runtime.sim)
  cint(not runtime.player.hashValidationFailed)
proc seek(tick: cint) {.exportc:"cogball_browser_seek", cdecl.} =
  runtime.player.seekReplay(runtime.sim,int(tick))
proc draw(width,height: cint): cint {.exportc:"cogball_browser_draw", cdecl.} =
  if width <= 0 or height <= 0: return 0
  let before = toFlatty(runtime.sim)
  glViewport(0,0,width,height)
  glClearColor(0.025,0.03,0.05,1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  renderer.addScene(snapshot(runtime.sim))
  var projection = overheadProjection()
  # Fit the same world rectangle at any canvas aspect ratio.
  let aspect = width.float32 / height.float32
  if aspect > 4'f32/3: projection[0,0] = 1 / (18 * aspect)
  else: projection[2,1] = -aspect / 24
  renderer.draw(projection)
  glFinish()
  cint(toFlatty(runtime.sim) == before)
proc negative(): cint {.exportc:"cogball_browser_negative", cdecl.} =
  let before = toFlatty(runtime.sim)
  var privateSim = runtime.sim
  privateSim.activeDirective[Azure].note = "PRIVATE_COACH_SENTINEL"
  privateSim.activeDirective[Crimson].robots[0].say = "PRIVATE_PROVIDER_SENTINEL"
  privateSim.config.model = "PRIVATE_TRAINING_SENTINEL"
  doAssert proofJson(privateSim) == proofJson(runtime.sim)
  doAssert "PRIVATE_" notin $proofJson(privateSim)
  var bad = runtime.player.data
  bad.hashes = @[]
  for hash in runtime.player.data.hashes: bad.hashes.add(hash)
  bad.hashes[0].hash = bad.hashes[0].hash xor 1'u64
  var rejected = false
  try: discard initReplayRuntime(bad,true,false)
  except ReplayError: rejected = true
  cint(rejected and toFlatty(runtime.sim) == before)

# Match the shipped Cogball viewer: keep Nim globals alive for exported calls.
proc liveRuntime() {.importc:"emscripten_exit_with_live_runtime", cdecl.}
liveRuntime()
