## Source-owned request and response evidence. Fixtures are not serving authority.
import std/[base64, json, options, os]
import bitworld/[decision_trajectory, native_http]
import cogball/[llm, sim]

putEnv("COWORLD_LLM_ENDPOINT", "")
putEnv("ANTHROPIC_API_KEY", "RETIRED_PROVIDER_CREDENTIAL_SENTINEL")
doAssert newLlmClient(defaultGameConfig()).disabled
putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:1")
putEnv("COWORLD_LLM_MODEL", "fixture-model")
let client = newLlmClient(defaultGameConfig())
let request = client.requestFor("private system", "private user", 1)
doAssert request.url == "http://127.0.0.1:1/v1/messages"
doAssert request.headers["X-Coworld-Player-Slot"] == "1"
let body = parseJson(request.body)
doAssert body["model"].getStr() == "fixture-model"
doAssert body["system"].getStr() == "private system"
doAssert body["messages"][0]["content"].getStr() == "private user"

var attempt = newDecisionAttempt("fixture-complete", "native-fixture", aoModel)
attempt.decoder = %*{"temperature": 1, "max_tokens": client.maxOutputTokens}
let decoder = copy(attempt.decoder)
let responseBody = $(%*{"model": "received-model", "stop_reason": "end_turn",
  "content": [{"type": "text", "text": "{}"}],
  "usage": {"input_tokens": 2, "output_tokens": 1},
  "sampling_evidence": {"prompt_token_ids": [1, 2], "completion_token_ids": [3],
    "behavior_log_probs": [-0.5], "stop_reason": "eos"}})
let headers = "HTTP/1.1 200 OK\r\nrequest-id: fixture-request\r\n" &
  "X-Softmax-Llm-Call-Id: 11111111-1111-4111-8111-111111111111\r\n\r\n"
let response = NativeHttpResponse(kind: nhComplete, httpStatus: some(200),
  headerBytes: headers, bodyBytes: responseBody, transferComplete: true,
  responseReaderJoined: some(true), latencyMs: some(7.0))
doAssert client.completionText(response, attempt) == "{}"
doAssert attempt.responseBodyB64.get() == encode(responseBody)
doAssert attempt.responseHeadersB64.get() == encode(headers)
doAssert attempt.responseComplete.get()
doAssert attempt.responseReaderJoined.get()
doAssert attempt.providerRequestId.get() == "fixture-request"
doAssert attempt.model.get() == "received-model"
doAssert attempt.promptTokenIds.get() == @[1, 2]
doAssert attempt.sampledTokenIds.get() == @[3]
doAssert attempt.behaviorLogprobs.get() == @[-0.5]
doAssert attempt.decoder == decoder

var partial = newDecisionAttempt("fixture-partial", "native-fixture", aoModel)
let interrupted = NativeHttpResponse(kind: nhInterrupted, httpStatus: some(200),
  headerBytes: "HTTP/1.1 200 OK\r\n\r\n", bodyBytes: "PRIVATE_PARTIAL_SENTINEL",
  transferComplete: false, responseReaderJoined: some(true), latencyMs: some(3.0))
doAssertRaises(CogballError):
  discard client.completionText(interrupted, partial)
doAssert partial.rawResponse.getStr() == "PRIVATE_PARTIAL_SENTINEL"
doAssert partial.responseBodyB64.get() == encode("PRIVATE_PARTIAL_SENTINEL")
doAssert not partial.responseComplete.get()
doAssert partial.responseReaderJoined.get()
doAssert partial.platformCallId.isNone
doAssert partial.response.kind == JNull

echo "native request, exact received bytes, unchanged decoder, and partial joined evidence passed"
