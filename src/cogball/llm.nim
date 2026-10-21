## Native sidecar completion and authoritative action parsing for the prompt player.
## Missing native endpoint selects unsupervised fallback. Provider credentials
## never activate inference. The game owns directive validation and actuators.

import
  std/[base64, json, math, options, os, parsejson, sets, streams, strutils, tables],
  bitworld/[decision_trajectory, native_http],
  sim

from std/unicode import validateUtf8

const
  AnthropicVersion = "2023-06-01"

type
  LlmRequest* = object
    ## One prepared HTTP call made by the prompt player.
    url*: string
    headers*: HttpHeaders
    body*: string

  LlmClient* = ref object
    sidecarEndpoint: string
    model*: string
    maxOutputTokens*: int
    temperature*: float
    disabled*: bool            ## true when no native endpoint is configured.

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    temperature: parseFloat(getEnv("COWORLD_LLM_TEMPERATURE", "1"))
  )
  if classify(result.temperature) in {fcNan, fcInf, fcNegInf} or
      result.temperature < 0 or result.temperature > 1:
    raise newException(ValueError, "COWORLD_LLM_TEMPERATURE must be finite and in 0..1")
  result.sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip().strip(
    chars = {'/'}, leading = false)
  result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
  if result.model.len == 0 or result.maxOutputTokens <= 0:
    raise newException(ValueError, "native model and positive token budget are required")
  result.disabled = result.sidecarEndpoint.len == 0

proc userPrompt*(view: JsonNode, operatorPrompt: string): string =
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the rules; " &
    "always reply in the requested format):\n" & operatorPrompt & "\n\n" & $view

proc requestFor*(client: LlmClient, system, user: string, slot: int): LlmRequest =
  if slot < 0:
    raise newException(ValueError, "native request requires an assigned seat")
  let body = %*{
    "model": client.model,
    "max_tokens": client.maxOutputTokens,
    "temperature": client.temperature,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  result.headers["content-type"] = "application/json"
  result.headers["X-Coworld-Player-Slot"] = $slot
  result.headers["anthropic-version"] = AnthropicVersion
  result.url = client.sidecarEndpoint & "/v1/messages"
  result.body = $body

proc completionText*(client: LlmClient, response: NativeHttpResponse,
    evidence: var DecisionAttempt): string =
  evidence.latencyMs = response.latencyMs
  evidence.responseReaderJoined = response.responseReaderJoined
  let observedResponse = response.httpStatus.isSome or response.headerBytes.len > 0 or response.bodyBytes.len > 0
  if observedResponse:
    evidence.responseBodyB64 = some(encode(response.bodyBytes))
    evidence.responseHeadersB64 = some(encode(response.headerBytes))
    evidence.responseComplete = some(response.transferComplete)
    evidence.httpStatus = response.httpStatus
    if validateUtf8(response.bodyBytes) == -1:
      evidence.rawResponse = %response.bodyBytes
  if validateUtf8(response.headerBytes) != -1:
    raise newException(CogballError, "received HTTP headers are not valid UTF-8")
  var responseHeaders: HttpHeaders
  var receivedHeaders = initTable[string, string]()
  var identityHeaders = initHashSet[string]()
  for line in response.headerBytes.splitLines():
    if line.startsWith("HTTP/"):
      responseHeaders.setLen(0)
      receivedHeaders.clear()
      identityHeaders.clear()
    elif line.len > 0:
      let colon = line.find(':')
      if colon <= 0:
        raise newException(CogballError, "invalid received HTTP header")
      let name = line[0 ..< colon]
      let value = line[colon + 1 .. ^1].strip()
      let normalized = name.toLowerAscii()
      if normalized in ["request-id", "x-request-id", "x-softmax-llm-call-id",
          "x-coworld-checkpoint-sha256", "x-coworld-tokenizer-sha256",
          "x-coworld-chat-template-sha256"]:
        if normalized in identityHeaders:
          raise newException(CogballError, "duplicate received identity header")
        identityHeaders.incl(normalized)
      responseHeaders.add((name, value))
      receivedHeaders[name] = value
  if observedResponse:
    evidence.responseHeaders = some(receivedHeaders)
  if responseHeaders.contains("request-id") and responseHeaders.contains("x-request-id") and
      responseHeaders["request-id"] != responseHeaders["x-request-id"]:
    raise newException(CogballError, "conflicting received request identity headers")
  for key in ["request-id", "x-request-id"]:
    if responseHeaders.contains(key):
      evidence.providerRequestId = some(responseHeaders[key])
      break
  for (header, field) in [
      ("x-softmax-llm-call-id", "call"),
      ("x-coworld-checkpoint-sha256", "model"),
      ("x-coworld-tokenizer-sha256", "tokenizer"),
      ("x-coworld-chat-template-sha256", "template")]:
    if responseHeaders[header].len > 0:
      case field
      of "call":
        let identity = responseHeaders[header]
        if identity.len != 36:
          raise newException(CogballError, "received platform call identity is not a UUID")
        for index, character in identity:
          if index in [8, 13, 18, 23]:
            if character != '-':
              raise newException(CogballError, "received platform call identity is not a UUID")
          elif character notin {'0'..'9', 'a'..'f', 'A'..'F'}:
            raise newException(CogballError, "received platform call identity is not a UUID")
        evidence.platformCallId = some(identity)
      of "model": evidence.modelIdentity = some(responseHeaders[header])
      of "tokenizer": evidence.tokenizerIdentity = some(responseHeaders[header])
      else: evidence.chatTemplateSha256 = some(responseHeaders[header])
  if response.kind != nhComplete:
    raise newException(CogballError, "native transport " & $response.kind)
  let status = response.httpStatus.get()
  if status == 401 or status == 403:
    client.disabled = true
    raise newException(CogballError, "native inference auth failed (" & $status & ")")
  if status == 429:
    raise newException(CogballError, "native inference throttled (429)")
  if status < 200 or status >= 300:
    raise newException(CogballError, "native inference error " & $status)
  let payload = parseJson(response.bodyBytes)
  if payload.kind != JObject or payload["model"].kind != JString or
      payload["content"].kind != JArray:
    raise newException(CogballError, "native response violates the completion schema")
  evidence.model = some(payload["model"].getStr())
  case payload["stop_reason"].kind
  of JString: evidence.stopReason = some(payload["stop_reason"].getStr())
  of JNull: discard
  else: raise newException(CogballError, "native stop reason must be text or null")
  if payload.hasKey("usage") and payload["usage"].kind != JNull:
    let usage = payload["usage"]
    if usage.kind != JObject or usage["input_tokens"].kind != JInt or
        usage["output_tokens"].kind != JInt or usage["input_tokens"].getInt() < 0 or
        usage["output_tokens"].getInt() < 0:
      raise newException(CogballError, "native usage must contain nonnegative integer counts")
    evidence.inputTokens = some(usage["input_tokens"].getInt())
    evidence.outputTokens = some(usage["output_tokens"].getInt())
  if payload.hasKey("sampling_evidence") and payload["sampling_evidence"].kind != JNull:
    let sampling = payload["sampling_evidence"]
    if sampling.kind != JObject or sampling["prompt_token_ids"].kind != JArray or
        sampling["completion_token_ids"].kind != JArray or sampling["stop_reason"].kind != JString:
      raise newException(CogballError, "native sampling evidence violates the token schema")
    var promptIds, sampledIds: seq[int]
    var probabilities: seq[float]
    for token in sampling["prompt_token_ids"]:
      if token.kind != JInt or token.getInt() < 0:
        raise newException(CogballError, "native prompt token IDs must be nonnegative integers")
      promptIds.add(token.getInt())
    for token in sampling["completion_token_ids"]:
      if token.kind != JInt or token.getInt() < 0:
        raise newException(CogballError, "native sampled token IDs must be nonnegative integers")
      sampledIds.add(token.getInt())
    if sampling["behavior_log_probs"].kind != JNull:
      if sampling["behavior_log_probs"].kind != JArray:
        raise newException(CogballError, "native draw probabilities must be an array or null")
      for probability in sampling["behavior_log_probs"]:
        if probability.kind notin {JInt, JFloat} or
            classify(probability.getFloat()) in {fcNan, fcInf, fcNegInf} or probability.getFloat() > 0:
          raise newException(CogballError, "native draw probabilities must be finite nonpositive numbers")
        probabilities.add(probability.getFloat())
      if probabilities.len != sampledIds.len:
        raise newException(CogballError, "native draw probabilities must match sampled token IDs")
    evidence.promptTokenIds = some(promptIds)
    evidence.sampledTokenIds = some(sampledIds)
    if sampling["behavior_log_probs"].kind != JNull:
      evidence.behaviorLogprobs = some(probabilities)
    evidence.stopReason = some(sampling["stop_reason"].getStr())
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(CogballError, "native inference refusal")
  for contentBlock in payload["content"]:
    if contentBlock.kind != JObject or contentBlock["type"].kind != JString:
      raise newException(CogballError, "native content block violates the completion schema")
    if contentBlock["type"].getStr() == "text":
      if contentBlock["text"].kind != JString:
        raise newException(CogballError, "native text content must be text")
      result.add(contentBlock["text"].getStr())
  evidence.response = %result
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(CogballError, "native reply ended before a JSON action")

type JsonProposal* = object
  ok*: bool
  node*: JsonNode
  reason*: string

proc jsonProposal*(text: string): JsonProposal =
  ## One domain parse boundary shared by prompt players and training bridges.
  let first = text.find('{')
  let last = text.rfind('}')
  if first < 0 or last <= first:
    return JsonProposal(node: newJNull(), reason: "no JSON object in response")
  let body = text[first .. last]
  var parser: JsonParser
  parser.open(newStringStream(body), "coach response")
  defer: parser.close()
  while true:
    parser.next()
    if parser.kind == jsonError:
      return JsonProposal(node: newJNull(), reason: parser.errorMsg())
    if parser.kind == jsonEof: break
  JsonProposal(ok: true, node: parseJson(body))

proc extractJsonObject*(text: string): JsonNode =
  let proposal = jsonProposal(text)
  if not proposal.ok: raise newException(CogballError, proposal.reason)
  proposal.node
