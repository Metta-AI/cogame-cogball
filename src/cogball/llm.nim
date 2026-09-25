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
  std/[json, os, strutils],
  bitworld/runtime,
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
    maxOutputTokens: config.maxOutputTokens
  )
  let sidecarEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("BEDROCK_MODEL")
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

proc requestFor*(client: LlmClient, system, user: string): LlmRequest =
  ## Both routes speak Anthropic Messages. Haiku 4.5 rejects effort settings.
  var body = %*{
    "model": client.model,
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  result.headers["content-type"] = "application/json"
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

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the outermost `{...}` object out of a model response, tolerating
  ## markdown fences and a prose prefix (babel's, ported unchanged).
  let
    start = text.find('{')
    stop = text.rfind('}')
  if start < 0 or stop <= start:
    var head = text.strip()
    if head.len > 160:
      head = head[0 ..< 160] & "..."
    raise newException(CogballError,
      "no JSON object in response: " & head.replace("\n", " "))
  parseJson(text[start .. stop])
