"""Claude-backed coaching for cogball, with an instant scripted fallback.

The **game server** owns the LLM client (the parley/babel lineage), not the
player container: the hosted Bedrock sidecar credential and the
``anthropic_api_key`` Coworld secret are injected into the game pod, the
"one parallel batch per turn" property is a game-server property, and
keeping the scripted layer server-side makes the recorded action log
reproducible with no network in the loop.

Credentials, in order of preference (babel's ladder, verbatim in order):

1. Bedrock sidecar — ``AWS_ENDPOINT_URL_BEDROCK_RUNTIME`` /
   ``AWS_BEARER_TOKEN_BEDROCK`` (hosted pods)
2. ``ANTHROPIC_API_KEY``
3. ``ANTHROPIC_API_KEY_URI`` (a URI holding the key)
4. none — the client disables itself and every turn falls back instantly
   with no network wait, so offline certification completes in seconds.

Both seats' calls go out as **one parallel batch per decision turn**: a
single ``asyncio.gather`` wrapped in a single ``asyncio.wait_for`` on the
turn budget.  Seats are never queried sequentially — that is what keeps a
48-turn match inside 60 % of the platform's episode timeout.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from dataclasses import dataclass
from typing import Any, Callable

import aiohttp

from . import defaults, uris

ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION = "2023-06-01"
BEDROCK_ANTHROPIC_VERSION = "bedrock-2023-05-31"

# Bedrock inference-profile candidates, tried in order; BEDROCK_MODEL pins
# one. Model access is a per-account Marketplace subscription, so an id that
# works in one account 403s in another. Haiku leads: hosted Bedrock capacity
# is shared account-wide and the sonnet profiles run out of tokens first.
BEDROCK_MODEL_CANDIDATES = (
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
)
DEFAULT_ANTHROPIC_MODEL = "claude-haiku-4-5-20251001"

SYSTEM_PROMPT = """\
You are the coach of a three-robot soccer team in a continuous 2D physics world.
Every 5 seconds of match time you issue ONE directive for all three of your robots.
A deterministic controller executes your directive for the next 5 seconds: it steers
each robot toward its target, turns it to face where it is going, and kicks when the
ball is in range and the intent allows it. You do not control motors directly.
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"note":"<=160 chars","robots":[
  {"id":"<one of your three robot ids>",
   "role":"keeper|back|wing|striker",
   "intent":"chase|intercept|hold|shoot|pass|clear|press",
   "target":[x,y],            // metres, pitch is x in [-20,20], y in [-12.5,12.5]
   "pass_to":"<teammate id or null>",
   "kick":"auto|never",
   "say":"<=48 chars"} , ... exactly three, one per robot ]}
Intents: chase = drive at the ball; intercept = drive to where the ball will be;
hold = hold the target point and face the ball; shoot = line up behind the ball and
strike it at their goal; pass = same but aimed at pass_to; clear = hammer it away
from your own goal; press = shadow the nearest opponent. target is used directly by
hold and as a bias by the others. kick:"never" makes the robot shepherd the ball
instead of striking it."""

RETRY_HINT = ("\n\nYour previous reply was unusable. Reply with ONLY the JSON "
              "object described above, beginning with '{', with exactly three "
              "robot entries using your own robot ids.")


@dataclass
class LlmRequest:
    """One seat's turn: the user message plus the reply validator.

    ``validate`` turns raw reply text into whatever the caller wants (a
    Directive) and raises on an unusable reply — which is what makes the
    retry fire before the scripted fallback.
    """

    seat: int
    user: str
    validate: Callable[[str], Any]


@dataclass
class LlmResult:
    seat: int
    value: Any = None
    cause: str | None = None      # a defaults.FALLBACK_CAUSES key
    detail: str = ""
    attempts: int = 0
    latency_ms: int = 0
    attempt_failures: tuple[tuple[int, str, str], ...] = ()

    @property
    def ok(self) -> bool:
        return self.cause is None and self.value is not None


class LlmClient:
    """Bedrock/Anthropic transport with the credential ladder above."""

    def __init__(self, *, attempt_deadlines=defaults.LLM_ATTEMPT_SECONDS):
        self.attempt_deadlines = tuple(attempt_deadlines)
        self.disabled = False
        self.transport = "none"
        self._api_key = ""
        self._bedrock_endpoint = ""
        self._bedrock_token = ""
        self._bedrock_models: list[str] = []
        self._bedrock_index = 0
        self.model = os.environ.get(
            "ANTHROPIC_MODEL", "").strip() or DEFAULT_ANTHROPIC_MODEL
        self._session: aiohttp.ClientSession | None = None
        self._resolved = False

    # -- credentials -------------------------------------------------------

    async def resolve(self) -> None:
        """Discover credentials once. Never raises."""
        if self._resolved:
            return
        self._resolved = True
        endpoint = os.environ.get("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "").strip()
        token = os.environ.get("AWS_BEARER_TOKEN_BEDROCK", "").strip()
        if endpoint or token:
            region = os.environ.get(
                "AWS_REGION") or os.environ.get(
                    "AWS_DEFAULT_REGION") or "us-west-2"
            if not endpoint:
                endpoint = f"https://bedrock-runtime.{region}.amazonaws.com"
            self.transport = "bedrock"
            self._bedrock_endpoint = endpoint.rstrip("/")
            self._bedrock_token = token
            pinned = os.environ.get("BEDROCK_MODEL", "").strip()
            self._bedrock_models = [pinned] if pinned else \
                list(BEDROCK_MODEL_CANDIDATES)
            print(f"cogball llm: bedrock transport, endpoint "
                  f"{self._bedrock_endpoint}, model "
                  f"{self._bedrock_models[0]}", file=sys.stderr)
            return

        key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
        if not key:
            uri = os.environ.get("ANTHROPIC_API_KEY_URI", "").strip()
            if uri:
                try:
                    key = (await uris.read_uri(uri)).decode("utf-8").strip()
                except Exception as exc:  # never fatal: fall through to none
                    print(f"cogball llm: failed to fetch "
                          f"ANTHROPIC_API_KEY_URI: {exc}", file=sys.stderr)
        if key:
            self.transport = "anthropic"
            self._api_key = key
            print(f"cogball llm: anthropic transport, model {self.model}",
                  file=sys.stderr)
            return

        self.transport = "none"
        self.disabled = True
        print("cogball llm: no LLM credentials; falling back to the scripted "
              "baseline every turn", file=sys.stderr)

    async def close(self) -> None:
        if self._session is not None and not self._session.closed:
            await self._session.close()
        self._session = None

    # -- the batch ---------------------------------------------------------

    async def decide_batch(self, requests: list[LlmRequest | None],
                           turn_budget: float) -> list[LlmResult]:
        """Every seat's decision for one turn, issued as ONE parallel batch.

        A single ``gather`` under a single ``wait_for``: the two seats' HTTP
        calls overlap in flight, and the whole turn is bounded by
        ``turn_budget`` no matter how the individual attempts behave.
        """
        await self.resolve()
        results: list[LlmResult | None] = [None] * len(requests)

        async def run(index: int, request: LlmRequest | None) -> None:
            if request is None:
                results[index] = LlmResult(seat=index, cause="skipped")
                return
            results[index] = await self._attempts(request)

        try:
            await asyncio.wait_for(
                asyncio.gather(*(run(i, r) for i, r in enumerate(requests))),
                turn_budget)
        except (asyncio.TimeoutError, TimeoutError):
            pass
        for index, result in enumerate(results):
            if result is None:
                results[index] = LlmResult(
                    seat=index, cause="timeout",
                    detail=f"turn budget of {turn_budget:g}s elapsed")
        return results  # type: ignore[return-value]

    async def _attempts(self, request: LlmRequest) -> LlmResult:
        """One seat: first attempt, then exactly one retry, then give up."""
        if self.disabled:
            return LlmResult(seat=request.seat, cause="no_credentials",
                             detail="no LLM credentials available")
        started = time.monotonic()
        failures: list[tuple[int, str, str]] = []
        user = request.user
        for attempt, deadline in enumerate(self.attempt_deadlines, start=1):
            try:
                text = await asyncio.wait_for(
                    self._complete(SYSTEM_PROMPT, user), deadline)
            except (asyncio.TimeoutError, TimeoutError):
                failures.append((attempt, "timeout",
                                 f"no reply within {deadline:g}s"))
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                failures.append((attempt, "transport_error",
                                 f"{type(exc).__name__}: {exc}"))
                if self.disabled:
                    break
            else:
                try:
                    value = request.validate(text)
                except Exception as exc:
                    failures.append((attempt, "parse_error", str(exc)))
                else:
                    return LlmResult(
                        seat=request.seat, value=value, attempts=attempt,
                        latency_ms=int((time.monotonic() - started) * 1000),
                        attempt_failures=tuple(failures))
            user = request.user + RETRY_HINT
        cause = failures[-1][1] if failures else "transport_error"
        detail = failures[-1][2] if failures else "no attempt completed"
        return LlmResult(
            seat=request.seat, cause=cause, detail=detail,
            attempts=len(failures),
            latency_ms=int((time.monotonic() - started) * 1000),
            attempt_failures=tuple(failures))

    # -- transport ---------------------------------------------------------

    def _bedrock_url(self) -> str:
        model = self._bedrock_models[self._bedrock_index]
        return f"{self._bedrock_endpoint}/model/{model}/invoke"

    def _try_next_bedrock_model(self, why: str) -> bool:
        if self.transport != "bedrock":
            return False
        if self._bedrock_index + 1 >= len(self._bedrock_models):
            return False
        self._bedrock_index += 1
        print(f"cogball llm: {self._bedrock_models[self._bedrock_index - 1]} "
              f"unusable ({why}); falling back to "
              f"{self._bedrock_models[self._bedrock_index]}", file=sys.stderr)
        return True

    async def _complete(self, system: str, user: str) -> str:
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession()
        body: dict = {
            "max_tokens": defaults.LLM_MAX_OUTPUT_TOKENS,
            "temperature": defaults.LLM_TEMPERATURE,
            "system": system,
            "messages": [{"role": "user", "content": user}],
        }
        headers = {"content-type": "application/json"}
        if self.transport == "bedrock":
            body["anthropic_version"] = BEDROCK_ANTHROPIC_VERSION
            if self._bedrock_token:
                headers["authorization"] = f"Bearer {self._bedrock_token}"
            url = self._bedrock_url()
        else:
            body["model"] = self.model
            headers["x-api-key"] = self._api_key
            headers["anthropic-version"] = ANTHROPIC_VERSION
            url = ANTHROPIC_URL
        # No output_config.effort: Haiku 4.5 rejects the whole request with
        # a 400 when it is present.

        async with self._session.post(
                url, data=json.dumps(body), headers=headers) as resp:
            text = await resp.text()
            if resp.status in (401, 403):
                if "Model access is denied" in text and \
                        self._try_next_bedrock_model("no model access"):
                    raise RuntimeError(f"bedrock model access denied: "
                                       f"{text[:300]}")
                self.disabled = True
                raise RuntimeError(
                    f"llm auth failed ({resp.status}) at {url}: {text[:300]}")
            if resp.status == 429:
                self._try_next_bedrock_model("throttled")
                raise RuntimeError(f"llm throttled (429): {text[:300]}")
            if not 200 <= resp.status < 300:
                raise RuntimeError(
                    f"llm error {resp.status}: {text[:300]}")
        payload = json.loads(text)
        if payload.get("stop_reason") == "refusal":
            raise RuntimeError("llm refusal")
        out = "".join(
            block.get("text", "")
            for block in payload.get("content", [])
            if isinstance(block, dict) and block.get("type") == "text")
        if payload.get("stop_reason") == "max_tokens" and "{" not in out:
            raise RuntimeError(
                "reply cut off at max_tokens before any JSON: " + out[:160])
        return out
