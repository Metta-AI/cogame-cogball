## Jev selects ordinary coaching intents from one seat's private turn view.

import std/[json, os, strutils]
import curly

let Intents = %*{
  "chase": "Drive at the ball.",
  "intercept": "Meet the ball's path.",
  "hold": "Hold a defensive point and face the ball.",
  "shoot": "Line up a shot toward the opposing goal.",
  "pass": "Move the ball toward a teammate.",
  "clear": "Kick the ball away from your own goal.",
  "press": "Shadow the opponent nearest the ball."
}

proc jevConfigured*(): bool =
  getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    (getEnv("METTA_CAPTURE_URL").strip().len > 0 and
      getEnv("METTA_CAPTURE_KEY").strip().len > 0) or
    getEnv("TYPESAFE_API_KEY").strip().len > 0

proc bestChoice(answer: JsonNode): string =
  if answer["type"].getStr() != "choice":
    raise newException(ValueError, "Jev returned a non-choice answer")
  let probabilities = answer["probabilities"]
  if probabilities.len != Intents.len or
      answer["confidence"].getFloat() < 0 or
      answer["confidence"].getFloat() > 1:
    raise newException(ValueError, "Jev returned the wrong intent set")
  var best = -1.0
  var total = 0.0
  for choice, probability in probabilities.pairs:
    if not Intents.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown intent")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      result = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")

proc chooseJevAction*(view: JsonNode, seat, timeoutSeconds: int): JsonNode =
  var questions = newJObject()
  for index in 0 ..< view["your_robots"].len:
    let robot = view["your_robots"][index]
    questions["robot_" & $index] = %*{
      "type": "choice",
      "instructions": "Choose " & robot["id"].getStr() &
        "'s legal coaching intent for the next five seconds.",
      "criteria": Intents
    }

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  let endpoint =
    if sidecar.len > 0: sidecar
    elif capture.len > 0: capture
    else: getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
  let model =
    if sidecar.len > 0: "typesafe/jev-1.13"
    elif capture.len > 0: getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    else: getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  let key =
    if sidecar.len > 0: ""
    elif capture.len > 0: getEnv("METTA_CAPTURE_KEY").strip()
    else: getEnv("TYPESAFE_API_KEY").strip()
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $seat
  let body = %*{
    "model": model,
    "state": "You coach one three-robot soccer team. Both coaches decide " &
      "simultaneously. Choose only from this seat's private view:\n" & $view,
    "questions": questions
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, timeoutSeconds)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let answers = parseJson(response.body)["answers"]
  let ownGoalX = if view["you"]["defending_x"].getStr() == "-20": -17 else: 17
  let ball = view["ball"]["pos"]
  result = %*{"note": "Jev coaching choice", "robots": []}
  for index in 0 ..< view["your_robots"].len:
    let robot = view["your_robots"][index]
    let intent = bestChoice(answers["robot_" & $index])
    let target =
      if intent == "hold" and index == 0: %*[ownGoalX, ball[1]]
      else: ball
    result["robots"].add(%*{
      "id": robot["id"],
      "role": (if index == 0: "keeper" elif index == 1: "striker" else: "wing"),
      "intent": intent,
      "target": target,
      "pass_to": newJNull(),
      "kick": "auto",
      "say": ""
    })
