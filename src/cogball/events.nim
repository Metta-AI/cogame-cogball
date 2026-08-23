## The tier-2 event WIRE FORMAT, shared by live emission and re-simulation.
## Kept from ctf: the live server emits the same events as it plays, and both
## paths must produce byte-identical rows.
##
## `SimEvent` never enters `gameHash`, so nothing here can affect determinism.

import std/json

import ./sim

proc key*(kind: SimEventKind): string =
  case kind
  of Kick: "kick"
  of TouchEvent: "touch"
  of Shot: "shot"
  of Save: "save"
  of Pass: "pass"
  of Interception: "interception"
  of Post: "post"
  of Goal: "goal"
  of Kickoff: "kickoff"
  of Drop: "drop"
  of PhaseChange: "phase"
  of DirectiveEvent: "directive"

proc jsonRow*(event: SimEvent): JsonNode =
  ## One JSON-lines row. Positions are in VIEW metres so an analyst never has
  ## to know the micrometre convention.
  result = newJObject()
  result["tick"] = %event.tick
  result["kind"] = %event.kind.key()
  result["source"] = %event.source
  result["target"] = %event.target
  result["seat"] = %event.seat
  result["amount"] = %event.amount
  result["x"] = %(float(int(event.x) - int(CentreX)) / 1_000_000.0)
  result["y"] = %(float(int(event.y) - int(CentreY)) / 1_000_000.0)
  result["speed"] = %(float(event.speed) * 24.0 / 1_000_000.0)
  result["content"] = %event.content

proc eventsJsonl*(
    events: openArray[SimEvent], ticks: int, summaryExtra: JsonNode = nil
): string =
  ## The full JSON-lines stream: one row per event, then a summary.
  ##
  ## The trailing summary row is part of the contract, not decoration — it is
  ## how a reader distinguishes "this episode had no events" from "the file was
  ## truncated", and it carries the GameVersion the events were produced under.
  var lines = newSeqOfCap[string](events.len + 1)
  for event in events:
    lines.add($event.jsonRow())
  var summary = newJObject()
  summary["type"] = %"summary"
  summary["ticks"] = %ticks
  summary["events"] = %events.len
  summary["gameVersion"] = %GameVersion
  if summaryExtra != nil:
    for key, value in summaryExtra:
      summary[key] = value
  lines.add($summary)
  result = ""
  for line in lines:
    result.add(line)
    result.add('\n')
