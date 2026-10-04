## Malicious player evidence fixture over the actual private socket boundary.
import std/[json, monotimes, options, os, times]
import bitworld/decision_trajectory
import bitworld/native_websocket
block playerFixture:
  let deadline = getMonoTime() + initDuration(seconds = 120)
  let connection = connectNativeWebSocket(getEnv("COWORLD_PLAYER_WS_URL"), deadline, 16 * 1024 * 1024)
  doAssert connection.kind == wsReady
  let socket = connection.socket
  defer: closeNativeWebSocket(socket)
  let registration = $(%*{"type": "register", "kind": "external", "prompt": "", "policy": "trust-fixture"})
  var packet = newString(3 + registration.len)
  packet[0] = char(0x81)
  packet[1] = char(registration.len and 255)
  packet[2] = char((registration.len shr 8) and 255)
  for index, ch in registration: packet[index + 3] = ch
  doAssert socket.sendNativeBinary(packet, deadline).kind == wsReady
  var latestId = ""
  while true:
    let message = socket.receiveNativeMessage(deadline)
    if message.kind in {wsClosed, wsDeadline}: break
    doAssert message.kind == wsMessage
    if message.messageKind.get() == wsmBinary:
      doAssert socket.sendNativeBinary($char(0x85), deadline).kind == wsReady
    elif message.messageKind.get() == wsmText:
      let decision = parseJson(message.data)
      if decision["type"].getStr() == "stop":
        let cleanup = getMonoTime() + initDuration(milliseconds = decision["cleanup_budget_ms"].getInt())
        doAssert socket.sendCleanupText($( %*{"type": "stopped", "decision_id": latestId,
          "stop_id": decision["stop_id"], "worker_status": "no_active_call",
          "attempts": newJArray()}), cleanup).kind == wsReady
        while true:
          let receipt = socket.receiveCleanupMessage(cleanup)
          doAssert receipt.kind == wsMessage
          if receipt.messageKind.get() == wsmText:
            let ack = parseJson(receipt.data)
            if ack["type"].getStr() == "evidence_received": break
        break
      if decision["type"].getStr() != "decision": continue
      latestId = decision["decision_id"].getStr()
      let attack = getEnv("COWORLD_ATTACK")
      let view = decision["observation"]
      var robots = newJArray()
      for robot in view["your_robots"]:
        robots.add(%*{"id": robot["id"], "role": "wing", "intent": "hold",
          "target": robot["pos"], "pass_to": newJNull(), "kick": "never", "say": ""})
      let action = %*{"note": "wire action", "robots": robots}
      var evidence = newDecisionAttempt(decision["decision_id"].getStr() & "-" &
        $decision["seat"].getInt(), "trust-fixture", case attack
          of "teacher": aoTeacher
          of "human": aoHuman
          else: aoModel)
      evidence.prompt = copy(decision["messages"])
      var sampled = copy(action)
      if attack == "mismatch": sampled["note"] = %"different model action"
      evidence.response = %($sampled)
      if attack == "mismatch":
        evidence.response = newJNull()
        evidence.request = %*{"system": decision["messages"][0]["content"],
          "messages": [{"role": "user", "content": decision["messages"][1]["content"]}],
          "max_tokens": decision["transport"]["max_output_tokens"]}
        evidence.model = some("asserted-fixture-model")
        evidence.decoder = %*{"max_tokens": decision["transport"]["max_output_tokens"]}
        doAssert socket.sendNativeText($( %*{"type": "attempt_started",
          "decision_id": decision["decision_id"], "training_attempt": attemptEvidenceJson(evidence)}), deadline).kind == wsReady
        evidence.response = %($sampled)
        evidence.rawResponse = %($(%*{"model": "asserted-fixture-model",
          "content": [{"type": "text", "text": $sampled}]}))
        evidence.responseComplete = some(true)
        evidence.responseReaderJoined = some(true)
      doAssert socket.sendNativeText($( %*{"type": "action", "decision_id": decision["decision_id"], "action": action,
        "training_attempt": attemptEvidenceJson(evidence)}), deadline).kind == wsReady
