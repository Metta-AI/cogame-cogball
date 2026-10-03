## Included only by an explicitly instrumented build of the existing viewer.
## Exposes the allowlisted value snapshot, not codec/config/chat/provider data.
import ./snapshot
var proofState: string
proc cogballProofState(): cstring {.exportc:"cogball_proof_state",cdecl.} =
  proofState = $proofJson(game)
  proofState.cstring
proc cogballProofStep(): cint {.exportc:"cogball_proof_step",cdecl.} =
  replay.stepReplay(game)
  cint(not replay.hashValidationFailed)
proc cogballProofSeek(tick: cint) {.exportc:"cogball_proof_seek",cdecl.} =
  replay.seekReplay(game,int(tick))
proc cogballProofReset() {.exportc:"cogball_proof_reset",cdecl.} =
  game = initSimServer(game.config)
  game.gameEventLoggingEnabled = false
  replay = initReplayPlayer(replay.data)
