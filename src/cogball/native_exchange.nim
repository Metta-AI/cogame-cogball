## Engine-issued private calls remain owned through final reader acknowledgement.
import std/[base64, json, monotimes, options, strutils, sysrand, tables]
import mummy
import bitworld/decision_trajectory
import decide, sim

type
  NativeEvidenceStage* = enum
    nesStarted, nesReceived
  IssuedOperation* = ref object
    id*: string
    socket*: WebSocket
    seat*: Seat
    call*: BatchCall
    issuedAt*, deadline*: MonoTime
    started*: bool
    evidence*: Option[DecisionAttempt]
  NativeExchange* = ref object
    operations*: seq[IssuedOperation]
    targets*: Table[WebSocket, int]
    latest*: Table[WebSocket, string]

proc newNativeExchange*(): NativeExchange =
  NativeExchange(targets: initTable[WebSocket, int](), latest: initTable[WebSocket, string]())

proc issue*(exchange: NativeExchange, socket: WebSocket, seat: Seat,
    call: BatchCall, deadline: MonoTime): IssuedOperation =
  result = IssuedOperation(socket: socket, seat: seat, call: call,
    issuedAt: getMonoTime(), deadline: deadline)
  for value in urandom(16): result.id.add(toHex(value, 2).toLowerAscii())
  exchange.operations.add(result)
  exchange.latest[socket] = result.id

proc operation*(exchange: NativeExchange, socket: WebSocket, id: string): IssuedOperation =
  for issued in exchange.operations:
    if issued.id == id and issued.socket == socket: return issued
  raise newException(CogballError, "player evidence has no authenticated issued operation")

proc retainAttempt*(exchange: NativeExchange, socket: WebSocket, id: string,
    payload: JsonNode, receivedAt: MonoTime, stage: NativeEvidenceStage): IssuedOperation =
  result = exchange.operation(socket, id)
  if receivedAt < result.issuedAt:
    raise newException(CogballError, "player evidence preceded its issued operation")
  var evidence = readAttemptEvidence(payload)
  if evidence.attemptId != id & "-" & $ord(result.seat):
    raise newException(CogballError, "attempt identity differs from its issued operation")
  if evidence.origin in {aoTeacher, aoHuman}: evidence.origin = aoUnknown
  let expectedPrompt = %*[{"role": "system", "content": result.call.system},
    {"role": "user", "content": result.call.user}]
  if evidence.origin == aoModel:
    if evidence.request.kind != JObject or evidence.request["max_tokens"].kind != JInt or
        evidence.request["max_tokens"].getInt() <= 0 or
        evidence.request["max_tokens"].getInt() > result.call.maxOutputTokens:
      raise newException(CogballError, "native request exceeds its issued token cap")
    if evidence.prompt != expectedPrompt or evidence.request.kind != JObject or
        evidence.request["system"] != %result.call.system or
        evidence.request["messages"] != %*[{"role": "user", "content": result.call.user}]:
      raise newException(CogballError, "native attempt differs from issued private messages")
    if stage == nesStarted:
      if evidence.response.kind != JNull or evidence.rawResponse.kind != JNull or
          evidence.platformCallId.isSome or evidence.providerRequestId.isSome or
          evidence.responseHeaders.isSome or evidence.responseBodyB64.isSome or
          evidence.responseHeadersB64.isSome or evidence.responseComplete.isSome or
          evidence.responseReaderJoined.isSome or evidence.httpStatus.isSome or
          evidence.latencyMs.isSome or evidence.inputTokens.isSome or evidence.outputTokens.isSome or
          evidence.modelIdentity.isSome or evidence.tokenizerIdentity.isSome or
          evidence.chatTemplateSha256.isSome or evidence.stopReason.isSome or evidence.rejectionReason.isSome or
          evidence.promptTokenIds.isSome or evidence.sampledTokenIds.isSome or evidence.behaviorLogprobs.isSome:
        raise newException(CogballError, "native start already contains response evidence")
    elif not result.started:
      raise newException(CogballError, "native evidence lacks its genuine issued start")
  if result.evidence.isSome:
    let before = attemptEvidenceJson(result.evidence.get())
    let after = attemptEvidenceJson(evidence)
    for field in ["prompt", "request", "decoder", "policy", "origin"]:
      if after[field] != before[field]:
        raise newException(CogballError, "native progress changed its started request")
    if stage == nesStarted or ((before["latency_ms"].kind != JNull or
        before["response_reader_joined"] == %true) and before != after):
      raise newException(CogballError, "finished native evidence is immutable")
    for field in ["response_body_b64", "response_headers_b64"]:
      if before[field].kind != JNull and (after[field].kind != JString or
          not decode(after[field].getStr()).startsWith(decode(before[field].getStr()))):
        raise newException(CogballError, "received native bytes cannot be rewritten")
    if before["response_complete"] == %true:
      for field in ["response_complete", "response_body_b64", "response_headers_b64"]:
        if before[field] != after[field]:
          raise newException(CogballError, "complete native bytes are immutable")
    for field in ["http_status", "response_headers", "platform_call_id", "provider_request_id",
        "model_identity", "tokenizer_identity", "chat_template_sha256"]:
      if before[field].kind != JNull and before[field] != after[field]:
        raise newException(CogballError, "received native identity is immutable")
  result.started = result.started or stage == nesStarted
  result.evidence = some(evidence)

proc validateModelAction*(issued: IssuedOperation) =
  let evidence = issued.evidence.get()
  if evidence.origin != aoModel: return
  if not issued.started or evidence.responseComplete != some(true) or
      evidence.responseReaderJoined != some(true) or evidence.rawResponse.kind != JString or
      evidence.response.kind != JString:
    raise newException(CogballError, "native action requires its started complete joined response")
  let payload = parseJson(evidence.rawResponse.getStr())
  if payload.kind != JObject or payload["model"].kind != JString or
      evidence.model != some(payload["model"].getStr()) or payload["content"].kind != JArray:
    raise newException(CogballError, "native body differs from normalized model evidence")
  var text = ""
  for content in payload["content"]:
    if content.kind != JObject or content["type"].kind != JString:
      raise newException(CogballError, "invalid native content block")
    if content["type"].getStr() == "text":
      if content["text"].kind != JString:
        raise newException(CogballError, "native content is not text")
      text.add(content["text"].getStr())
  if evidence.response != %text:
    raise newException(CogballError, "native body differs from selected completion")

proc finalAttempts*(exchange: NativeExchange): Table[string, DecisionAttempt] =
  result = initTable[string, DecisionAttempt]()
  for issued in exchange.operations:
    if issued.evidence.isSome:
      let attempt = issued.evidence.get()
      result[attempt.attemptId] = attempt
