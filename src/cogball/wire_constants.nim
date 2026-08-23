## The JS wire-constants block: the handful of engine constants the browser
## chromes must agree with (playback speeds, fps, the chrome sprite id, the FX
## tuning). Historically each HTML client re-typed these as literals and
## nothing enforced agreement — a retuned PlaybackSpeeds would silently desync
## every client. This module renders them ONCE, from the same Nim consts the
## engine runs on; server.nim splices the block into every served client page,
## and tools/gen_wire_constants.nim emits it for the static wasm bundle.
## Clients read `window.COGBALL_WIRE` and keep their old literals only as
## fallbacks for raw file:// opens of the un-spliced sources.

import std/strutils
import sim, global

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  "window.COGBALL_WIRE={speeds:" & jsIntArray(PlaybackSpeeds) &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",kickFxTicks:" & $KickFxTicks &
  ",goalFxTicks:" & $GoalFxTicks &
  ",turnTicks:" & $DefaultTurnTicks &
  ",boardScale:" & $BoardScale &
  ",boardW:" & $BoardW &
  ",boardH:" & $BoardH &
  "};"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder both client HTML files carry where the block belongs
  ## (before any script that reads window.COGBALL_WIRE).

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
