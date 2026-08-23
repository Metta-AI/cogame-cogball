#!/usr/bin/env python3
"""Summarise a cogball `.bitreplay` as one strict-UTF-8 JSON object.

Python 3 standard library ONLY: no Nim, no Docker, no dependencies. This is the
phase-60 substitute for a JSON replay — cogball keeps the starter's binary
COWLDBAL format because the static wasm viewer literally parses it, so this
script is how a human (or a verification step) reads an episode out of the
bytes.

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                       # strict UTF-8 JSON
    jq -r '.protocol, .results.reason' /tmp/ep.json
    jq -r '[.directives[]|select(.source=="llm")]|length, .fallbacks' /tmp/ep.json

Output shape:

    {"protocol":"cogball/v1","gameVersion":"1","seed":679961,
     "names":[...],"aliases":["Azure","Crimson"],"policyKinds":[...],
     "tickCount":4800,"directives":[...],"fallbacks":N,"results":{...}}
"""

import gzip
import json
import struct
import sys
import zlib

MAGIC = b"COWLDBAL"
FORMAT_VERSION = 1

REC_HASH = 0x01
REC_INPUT = 0x02
REC_JOIN = 0x03
REC_LEAVE = 0x04
REC_CHAT = 0x05
REC_DEBUG_SPRITE = 0x06


class Reader:
    def __init__(self, data):
        self.data = data
        self.at = 0
        self.repaired = 0        # strings the replay bytes could not decode

    def take(self, count):
        if self.at + count > len(self.data):
            raise ValueError("replay is truncated at byte %d" % self.at)
        chunk = self.data[self.at:self.at + count]
        self.at += count
        return chunk

    def u8(self):
        return self.take(1)[0]

    def u16(self):
        return struct.unpack("<H", self.take(2))[0]

    def i16(self):
        return struct.unpack("<h", self.take(2))[0]

    def u32(self):
        return struct.unpack("<I", self.take(4))[0]

    def u64(self):
        return struct.unpack("<Q", self.take(8))[0]

    def text(self):
        # Strict FIRST. This script's promise is strict-UTF-8 JSON on stdout,
        # and decoding everything with errors="replace" would meet that promise
        # by construction rather than because the replay bytes are clean -- a
        # byte-truncated string would be silently healed into U+FFFD and the
        # reader would never learn that the writer's rune discipline had
        # failed. So a repair is still made (a forensics tool must not die on
        # the bytes it exists to diagnose) but it is COUNTED, and main() says
        # so on stderr.
        raw = self.take(self.u16())
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError:
            self.repaired += 1
            return raw.decode("utf-8", "replace")

    def blob(self):
        return self.take(self.u32())


def decompress(raw):
    """Hosted artifacts may arrive gzip- or zlib-wrapped."""
    if raw.startswith(MAGIC):
        return raw
    for opener in (gzip.decompress, zlib.decompress):
        try:
            out = opener(raw)
        except Exception:
            continue
        if out.startswith(MAGIC):
            return out
    return raw


def brace_match(text, start):
    """The outermost {...} beginning at `start` — the technique paintbot's
    AGENTS.md documents for prod forensics, kept because a config echo can
    legitimately contain nested objects."""
    depth = 0
    in_string = False
    escaped = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise ValueError("config JSON is unterminated")


def parse(raw):
    data = decompress(raw)
    reader = Reader(data)
    if reader.take(len(MAGIC)) != MAGIC:
        raise ValueError("not a cogball replay: magic does not match")
    version = reader.u16()
    if version != FORMAT_VERSION:
        raise ValueError("unsupported replay format version %d" % version)
    game_name = reader.text()
    game_version = reader.text()
    reader.u64()                       # recorded-at, milliseconds
    config_text = reader.text()
    config = json.loads(brace_match(config_text, config_text.index("{")))

    joins = []
    chats = []
    inputs = 0
    last_tick = -1
    ticks = 0
    chain = 14695981039346656037     # FNV-1a offset basis, 64-bit
    while reader.at < len(data):
        kind = reader.u8()
        if kind == REC_HASH:
            tick = reader.u32()
            value = reader.u64()
            if tick <= last_tick:
                break                  # the writer's stop-on-rewind rule
            last_tick = tick
            ticks = tick + 1
            # A digest OF the hash chain: two recordings of the same commit and
            # seed must agree on it, so CI can prove a committed fixture is not
            # stale without comparing bytes (the header carries a timestamp).
            chain = ((chain ^ value) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
        elif kind == REC_INPUT:
            reader.u32()
            reader.u8()
            reader.u8()
            inputs += 1
        elif kind == REC_JOIN:
            reader.u32()
            reader.u8()
            name = reader.text()
            reader.i16()
            reader.text()
            joins.append(name)
        elif kind == REC_LEAVE:
            reader.u32()
            reader.u8()
        elif kind == REC_CHAT:
            tick_ms = reader.u32()
            reader.u8()
            chats.append((tick_ms, reader.text()))
        elif kind == REC_DEBUG_SPRITE:
            reader.u32()
            reader.u8()
            reader.blob()
        else:
            raise ValueError("unknown replay record type 0x%02x" % kind)

    directives = []
    fallback_attempts = 0
    guards = []
    results = None
    kinds = [None, None]
    labels = [None, None]
    for tick_ms, text in chats:
        try:
            record = json.loads(text)
        except Exception:
            continue
        if not isinstance(record, dict):
            continue
        key = record.get("k")
        if key == "directive":
            directives.append({
                "turn": record.get("turn"),
                "seat": record.get("seat"),
                "alias": record.get("alias"),
                "source": record.get("source"),
                "latency_ms": record.get("latency_ms"),
                "note": record.get("note"),
                "intents": [r.get("intent") for r in record.get("robots", [])],
                "says": [r.get("say") for r in record.get("robots", [])],
            })
        elif key == "fallback":
            # One record per FAILED ATTEMPT, so attempt 1 leaves a record even
            # when the retry succeeds. See `fallbacks` below.
            fallback_attempts += 1
        elif key == "budget_guard":
            guards.append(record.get("turn"))
        elif key == "register":
            seat = record.get("seat")
            if isinstance(seat, int) and 0 <= seat < 2:
                kinds[seat] = record.get("kind")
                labels[seat] = record.get("policy")
        elif key == "result":
            results = record.get("results")

    # `fallbacks` is the number of TURNS that actually played the scripted
    # fallback, which is what the phase-60 check means by it: a `fallback`
    # record is written per failed ATTEMPT, so attempt 1 leaves one behind even
    # when the retry lands and the turn ends up sourced "llm". Counting records
    # would report more fallen-back turns than there were. The raw record count
    # stays available as `fallbackAttempts` for forensics.
    fallbacks = sum(1 for d in directives if d.get("source") == "fallback")

    names = [entry.get("name", "") for entry in config.get("players", [])]
    if joins:
        names = joins
    return {
        "protocol": "cogball/v1",
        "gameName": game_name,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "numAgents": config.get("num_agents"),
        "maxTicks": config.get("maxTicks"),
        "turnTicks": config.get("turnTicks"),
        "names": names,
        "aliases": ["Azure", "Crimson"],
        "policyKinds": kinds,
        "policyLabels": labels,
        "tickCount": ticks,
        "hashChain": "%016x" % chain,
        "utf8Repairs": reader.repaired,
        "inputRecords": inputs,
        "directives": directives,
        "fallbacks": fallbacks,
        "fallbackAttempts": fallback_attempts,
        "budgetGuards": guards,
        "results": results,
    }


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: replay_summary.py <replay.bitreplay>\n")
        return 2
    with open(argv[1], "rb") as handle:
        summary = parse(handle.read())
    # A repair means the REPLAY BYTES were not clean, not that this script
    # coped: say so loudly on stderr, where it cannot corrupt the JSON on
    # stdout that the caller parses.
    if summary["utf8Repairs"]:
        sys.stderr.write(
            "WARNING: %d string(s) in this replay are not valid UTF-8 and were "
            "repaired with U+FFFD; the writer's rune truncation is broken\n"
            % summary["utf8Repairs"])
    # ensure_ascii=False so a non-ASCII policy label or `say` stays itself; the
    # caller is promised STRICT UTF-8 JSON on stdout.
    sys.stdout.buffer.write(
        json.dumps(summary, ensure_ascii=False).encode("utf-8"))
    sys.stdout.buffer.write(b"\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
