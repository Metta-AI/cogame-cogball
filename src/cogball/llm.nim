## The LLM client: credential ladder and transport, ported from
## `cogame-babel/src/babel/llm.nim` into the ctf-lineage server.
##
## coworld-ctf has no LLM client in its episode server (its campaign strategist
## is a platform-side feature that ships with the `coworld` package in
## Metta-AI/metta, not in the repo), so this module is the one piece of the
## parley/babel lineage cogball carries across.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials the client is `disabled` and every turn falls back
## instantly with NO network wait, so offline certification completes in
## seconds. That fallback is load-bearing.
##
## The decision happens in the GAME server, not the player container: the
## `anthropic_api_key` coworld secret is injected into the game pod, phase 60
## greps the GAME log for `falling back`, and keeping the control layer
## server-side is what makes the recorded action log reproducible with no
## network in the loop.

import
  std/[json, os, strutils],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmRequest* = object
    ## One prepared HTTP call. `decide.nim` collects both seats' requests and
    ## issues them as ONE parallel batch per turn.
    url*: string
    headers*: HttpHeaders
    body*: string

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
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

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL pins
  ## one; without it, fall through this list — model access is a per-account
  ## Marketplace subscription, so an id that works in one account 403s in
  ## another. Haiku leads: hosted Bedrock capacity is shared account-wide and
  ## the sonnet profiles run out of daily tokens first.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel*(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "cogball llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "cogball llm: bedrock transport, url ", result.bedrockUrl
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
  ## Builds one prepared call. Body shape copied from babel as is:
  ## `max_tokens` 900 (400 truncates), no `output_config.effort` on Haiku 4.5
  ## (it 400s on it), no `temperature` (an untested field on a Bedrock body).
  ##
  ## `output_config.effort` is sent on the ANTHROPIC path only, and there only
  ## when the model string names neither `haiku` nor `4-5`. The BEDROCK body
  ## never carries it at all -- deliberately stricter than the rule, for the
  ## same reason `temperature` was dropped: an untested field on a Bedrock body
  ## is a 400 in production, `bedrockModelIds()` leads with a haiku-4-5 profile
  ## where the rule forbids the field anyway, and the field only trims cost, so
  ## the conservative side of the trade costs nothing that matters.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  result.headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    # No `output_config` here: see the docstring.
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      result.headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    result.headers["x-api-key"] = client.apiKey
    result.headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.body = $body

proc completionText*(client: LlmClient, code: int, body: string): string =
  ## Turns one HTTP response into the model's text, or raises with a short,
  ## quotable reason. Auth failures disable the client for the rest of the
  ## episode so no later turn pays another network wait.
  if code == 401 or code == 403:
    let detail = body[0 .. min(body.high, 400)]
    if "Model access is denied" in body and
        client.tryNextBedrockModel("no model access"):
      raise newException(CogballError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(CogballError,
      "llm auth failed (" & $code & "): " & detail)
  if code == 429:
    let detail = body[0 .. min(body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
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
