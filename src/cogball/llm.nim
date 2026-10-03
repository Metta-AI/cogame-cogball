## The LLM client: hosted sidecar and local Anthropic transport, ported from
## `cogame-babel/src/babel/llm.nim` into the ctf-lineage player.
##
## coworld-ctf has no LLM client in its episode server (its campaign strategist
## is a platform-side feature that ships with the `coworld` package in
## Metta-AI/metta, not in the repo), so this module is the one piece of the
## parley/babel lineage cogball carries across.
##
## Hosted pods use the model sidecar. Local runs can use ANTHROPIC_API_KEY or
## ANTHROPIC_API_KEY_URI.
## With no credentials the client is `disabled` and every turn falls back
## instantly with NO network wait, so offline certification completes in
## seconds. That fallback is load-bearing.
##
## The player owns inference and its credential. The game owns directive
## validation, actuator masks, fallback, results and replay.

import
  std/[json, math, options, os, parsejson, streams, strutils],
  bitworld/[runtime, decision_trajectory],
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"

type
  LlmTransport* = enum
    ltNone, ltSidecar, ltAnthropic

  LlmRequest* = object
    ## One prepared HTTP call made by the prompt player.
    url*: string
    headers*: HttpHeaders
    body*: string

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    sidecarEndpoint: string
    model*: string
    maxOutputTokens*: int
    temperature*: float
    disabled*: bool            ## true once credentials are known-unavailable.

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "cogball llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    temperature: parseFloat(getEnv("COWORLD_LLM_TEMPERATURE", "1"))
  )
  if classify(result.temperature) in {fcNan, fcInf, fcNegInf} or
      result.temperature < 0 or result.temperature > 1:
    raise newException(ValueError, "COWORLD_LLM_TEMPERATURE must be finite and in 0..1")
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
    echo "cogball llm: sidecar transport, model ", result.model
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "cogball llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "cogball llm: no LLM credentials; using scripted fallback"

proc requestFor*(client: LlmClient, system, user: string, slot: int): LlmRequest =
  ## Both routes speak Anthropic Messages. Haiku 4.5 rejects effort settings.
  var body = %*{
    "model": client.model,
    "max_tokens": client.maxOutputTokens,
    "temperature": client.temperature,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  result.headers["content-type"] = "application/json"
  if client.transport == ltSidecar and slot >= 0:
    result.headers["X-Coworld-Player-Slot"] = $slot
  result.headers["anthropic-version"] = AnthropicVersion
  if client.transport == ltSidecar:
    result.url = client.sidecarEndpoint & "/v1/messages"
  else:
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    result.headers["x-api-key"] = client.apiKey
    result.url = AnthropicUrl
  result.body = $body

proc completionText*(client: LlmClient, code: int, body: string): string =
  ## Turns one HTTP response into the model's text, or raises with a short,
  ## quotable reason. Auth failures disable the client for the rest of the
  ## episode so no later turn pays another network wait.
  if code == 401 or code == 403:
    let detail = body[0 .. min(body.high, 400)]
    client.disabled = true
    raise newException(CogballError,
      "llm auth failed (" & $code & "): " & detail)
  if code == 429:
    let detail = body[0 .. min(body.high, 300)]
    raise newException(CogballError, "llm throttled (429): " & detail)
  if code < 200 or code >= 300:
    raise newException(CogballError, "llm error " & $code & ": " &
      body[0 .. min(body.high, 300)])
  let payload = parseJson(body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(CogballError, "llm refusal")
  if not payload.hasKey("content"):
    raise newException(CogballError, "llm reply has no content block")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(CogballError, "reply cut off at max_tokens before " &
      "any JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

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

proc responseEvidence*(attempt: var DecisionAttempt, headers: HttpHeaders, body: string) =
  ## Preserve native metadata before the existing domain completion parser runs.
  attempt.rawResponse = %body
  if headers.contains("X-Softmax-Llm-Call-Id"):
    attempt.platformCallId = some(headers["X-Softmax-Llm-Call-Id"])
  for header in ["X-Coworld-Checkpoint-Sha256", "X-Coworld-Tokenizer-Sha256",
      "X-Coworld-Chat-Template-Sha256"]:
    if headers.contains(header):
      case header
      of "X-Coworld-Checkpoint-Sha256": attempt.modelIdentity = some(headers[header])
      of "X-Coworld-Tokenizer-Sha256": attempt.tokenizerIdentity = some(headers[header])
      else: attempt.chatTemplateSha256 = some(headers[header])

proc completionEvidence*(attempt: var DecisionAttempt, payload: JsonNode) =
  attempt.model = some(payload["model"].getStr())
  attempt.stopReason = some(payload["stop_reason"].getStr())
  if payload.hasKey("usage"):
    attempt.inputTokens = some(payload["usage"]["input_tokens"].getInt())
    attempt.outputTokens = some(payload["usage"]["output_tokens"].getInt())
  if payload.hasKey("sampling_evidence") and payload["sampling_evidence"].kind != JNull:
    let sampling = payload["sampling_evidence"]
    var promptIds, sampledIds: seq[int]
    var probabilities: seq[float]
    for token in sampling["prompt_token_ids"]: promptIds.add(token.getInt())
    for token in sampling["completion_token_ids"]: sampledIds.add(token.getInt())
    attempt.promptTokenIds = some(promptIds)
    attempt.sampledTokenIds = some(sampledIds)
    if sampling["behavior_log_probs"].kind != JNull:
      for probability in sampling["behavior_log_probs"]: probabilities.add(probability.getFloat())
      attempt.behaviorLogprobs = some(probabilities)
    attempt.stopReason = some(sampling["stop_reason"].getStr())
    attempt.decoder["sampling_evidence"] = copy(sampling)
