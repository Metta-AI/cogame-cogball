## Issued native chronology and immutable final facts are game-owned.
import std/[base64, json, monotimes, options, times]
import mummy
import bitworld/decision_trajectory
import cogball/[decide, native_exchange, sim]

var socket: WebSocket
let exchange = newNativeExchange()
let issued = exchange.issue(socket, Azure,
  BatchCall(seat: 0, maxOutputTokens: 128, system: "private rules", user: "private view", observation: newJObject()),
  getMonoTime() + initDuration(seconds = 1))
var evidence = newDecisionAttempt(issued.id & "-0", "native-fixture", aoModel)
evidence.prompt = %*[{"role": "system", "content": "private rules"},
  {"role": "user", "content": "private view"}]
evidence.request = %*{"model": "fixture", "max_tokens": 64, "system": "private rules",
  "messages": [{"role": "user", "content": "private view"}]}
evidence.model = some("fixture")
evidence.decoder = %*{"temperature": 1}
var excessive = evidence
excessive.request = copy(evidence.request)
excessive.request["max_tokens"] = %129
doAssertRaises(CogballError):
  discard exchange.retainAttempt(socket, issued.id, attemptEvidenceJson(excessive),
    getMonoTime(), nesStarted)
doAssert issued.evidence.isNone

var premature = evidence
premature.responseComplete = some(false)
doAssertRaises(CogballError):
  discard exchange.retainAttempt(socket, issued.id, attemptEvidenceJson(premature),
    getMonoTime(), nesStarted)
doAssert issued.evidence.isNone

discard exchange.retainAttempt(socket, issued.id, attemptEvidenceJson(evidence),
  getMonoTime(), nesStarted)
let body = $(%*{"model": "fixture", "content": [{"type": "text", "text": "{}"}]})
evidence.response = %"{}"
evidence.rawResponse = %body
evidence.responseBodyB64 = some(encode(body))
evidence.responseHeadersB64 = some(encode("HTTP/1.1 200 OK\r\n\r\n"))
evidence.httpStatus = some(200)
evidence.responseComplete = some(true)
evidence.responseReaderJoined = some(true)
evidence.latencyMs = some(3.0)
# Late facts remain retained; only the separate ingress window selects actions.
discard exchange.retainAttempt(socket, issued.id, attemptEvidenceJson(evidence),
  issued.deadline + initDuration(milliseconds = 1), nesReceived)
issued.validateModelAction()
var rewritten = evidence
rewritten.response = %"rewritten completion"
doAssertRaises(CogballError):
  discard exchange.retainAttempt(socket, issued.id, attemptEvidenceJson(rewritten),
    getMonoTime(), nesReceived)
doAssert issued.evidence.get().response == %"{}"
doAssertRaises(CogballError):
  discard exchange.retainAttempt(socket, "not-issued", attemptEvidenceJson(evidence),
    getMonoTime(), nesReceived)
