## Malicious player evidence fixture over the actual private socket boundary.
import std/[json, options, os]
import bitworld/decision_trajectory
import whisky
let socket = newWebSocket(getEnv("COWORLD_PLAYER_WS_URL"))
let registration = $(%*{"type": "register", "kind": "external", "policy": "trust-fixture"})
var packet = newString(3 + registration.len)
packet[0] = char(0x81)
packet[1] = char(registration.len and 255)
packet[2] = char((registration.len shr 8) and 255)
for index, ch in registration: packet[index + 3] = ch
socket.send(packet, BinaryMessage)
while true:
  let message = socket.receiveMessage(120_000)
  if message.isNone: break
  if message.get().kind == BinaryMessage:
    socket.send($char(0x85), BinaryMessage)
  elif message.get().kind == TextMessage:
    let decision = parseJson(message.get().data)
    if decision["type"].getStr() != "decision": continue
    let attack = getEnv("COWORLD_ATTACK")
    let view = decision["view"]
    var robots = newJArray()
    for robot in view["your_robots"]:
      robots.add(%*{"id": robot["id"], "role": "wing", "intent": "hold",
        "target": robot["pos"], "pass_to": newJNull(), "kick": "never", "say": ""})
    let action = %*{"note": "wire action", "robots": robots}
    var evidence = newDecisionAttempt($decision["id"].getInt() & "-" &
      $decision["seat"].getInt(), "trust-fixture", case attack
        of "teacher": aoTeacher
        of "human": aoHuman
        else: aoModel)
    evidence.prompt = %*[{"role": "system", "content": decision["system"]},
      {"role": "user", "content": $view}]
    var sampled = copy(action)
    if attack == "mismatch": sampled["note"] = %"different model action"
    evidence.response = %($sampled)
    evidence.rawResponse = copy(evidence.response)
    evidence.request = %*{"system": decision["system"], "messages": evidence.prompt}
    evidence.model = some("asserted-fixture-model")
    evidence.decoder = %*{"temperature": 0}
    socket.send($( %*{"type": "action", "id": decision["id"], "action": action,
      "training_attempt": attemptEvidenceJson(evidence)}), TextMessage)
