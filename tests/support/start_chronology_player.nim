## Exercise issued model starts and joined-response immutability over real sockets.
import std/[json, monotimes, options, os, times]
import bitworld/[decision_trajectory, native_websocket]

proc chatPacket(text: string): string =
  result = newString(3 + text.len)
  result[0] = char(0x81)
  result[1] = char(text.len and 0xff)
  result[2] = char((text.len shr 8) and 0xff)
  for i, value in text: result[3 + i] = value

let mode = getEnv("ASSERTED_CHRONOLOGY")
doAssert mode in ["first", "joined"]
let deadline = getMonoTime() + initDuration(seconds = 60)
let connected = connectNativeWebSocket(getEnv("COWORLD_PLAYER_WS_URL"), deadline,
  16 * 1024 * 1024)
doAssert connected.kind == wsReady
let socket = connected.socket
doAssert socket.sendNativeBinary(chatPacket($ %*{"type": "register", "kind": "prompt",
  "prompt": "private chronology fixture", "policy": "chronology-fixture",
  "scripted": newJNull()}), deadline).kind == wsReady
while true:
  let received = socket.receiveNativeMessage(deadline)
  if received.kind == wsClosed: break
  doAssert received.kind == wsMessage
  if received.messageKind.get() == wsmBinary:
    doAssert socket.sendNativeBinary($char(0x85), deadline).kind == wsReady
    continue
  let packet = parseJson(received.data)
  case packet["type"].getStr()
  of "decision":
    let id = packet["decision_id"].getStr()
    let messages = packet["messages"]
    var attempt = newDecisionAttempt(id & "-" & $packet["seat"].getInt(),
      "chronology-fixture", aoModel)
    attempt.prompt = copy(messages)
    attempt.request = %*{"model": "fixture/asserted", "system": messages[0]["content"],
      "messages": [{"role": "user", "content": messages[1]["content"]}],
      "temperature": 0, "max_tokens": packet["transport"]["max_output_tokens"]}
    attempt.decoder = %*{"temperature": 0, "max_tokens": packet["transport"]["max_output_tokens"]}
    attempt.model = some("fixture/asserted")
    if mode == "first": attempt.rejectionReason = some("already observed provider failure")
    doAssert socket.sendNativeText($ %*{"type": "attempt_started", "decision_id": id,
      "training_attempt": attempt.attemptEvidenceJson()}, deadline).kind == wsReady
    attempt.rejectionReason = none(string)
    var robots = newJArray()
    for robot in packet["observation"]["your_robots"]:
      robots.add(%*{"id": robot["id"], "role": "wing", "intent": "hold",
        "target": robot["pos"], "pass_to": newJNull(), "kick": "never", "say": ""})
    let action = %*{"note": "", "robots": robots}
    attempt.response = %($action)
    attempt.rawResponse = %($ %*{"model": "fixture/asserted",
      "content": [{"type": "text", "text": $action}]})
    attempt.httpStatus = some(200)
    attempt.responseComplete = some(true)
    attempt.responseReaderJoined = some(true)
    doAssert socket.sendNativeText($ %*{"type": "action", "decision_id": id,
      "action": action, "training_attempt": attempt.attemptEvidenceJson()}, deadline).kind == wsReady
    if mode == "joined":
      attempt.inputTokens = some(99)
      doAssert socket.sendNativeText($ %*{"type": "action", "decision_id": id,
        "action": action, "training_attempt": attempt.attemptEvidenceJson()}, deadline).kind == wsReady
  of "stop":
    doAssert socket.sendNativeText($ %*{"type": "stopped", "decision_id": packet["decision_id"],
      "stop_id": packet["stop_id"], "worker_status": "no_active_call", "attempts": []}, deadline).kind == wsReady
  of "evidence_received", "final": break
  else: doAssert false, "unexpected private control frame"
closeNativeWebSocket(socket)
