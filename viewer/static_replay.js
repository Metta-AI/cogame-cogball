// cogball static replay shell: fetches the replay named by ?replay=<url>
// (falling back to /replay-data for the game server's local viewer), hands
// the decoded action log to the wasm core — which re-simulates the match
// with the SAME physics the game server ran — and drives the DOM chrome:
// scorebug, clock, event feed, transport bar, goal banner and the instant
// slow-motion goal replay.
//
// The shell is the only thing on screen until the replay is in, so it has to
// be honest about waiting: the caption names what it is doing, a stalled
// fetch gives up after FETCH_TIMEOUT_MS instead of sitting on "LOADING"
// forever, and every failure offers a Retry that refetches without a page
// reload (the wasm module, once compiled, is reused).
(function () {
  "use strict";

  var FETCH_TIMEOUT_MS = 20000;
  var TICKS_PER_SECOND = 30;
  var BYTES_PER_TICK = 18;
  var PROTOCOL = "cogball/v1";

  // VIEWER -> HOST READINESS. An embedding page (the softmax.com theater, the
  // Observatory episode page) can only see this document's `load` event,
  // which fires long before the wasm module has compiled and the replay has
  // come back from S3. So the shell tells the parent what it is doing:
  // `loading` as soon as this script runs (before `load`, so the host never
  // mistakes document-load for a picture), `ready` once the renderer has
  // drawn its first frame, `error` when the replay cannot be shown. Same
  // envelope shape as the ctf-shell Escape bridge ({src, type}); no secrets
  // ride on it, so the target origin is "*".
  function tell(type, message) {
    if (window.parent === window) return;
    var envelope = { src: "coworld-replay", type: type };
    if (message) envelope.message = message;
    try { window.parent.postMessage(envelope, "*"); } catch (ignore) {}
  }
  tell("loading");

  var $ = function (id) { return document.getElementById(id); };
  var replay = null;      // the parsed replay document
  var totalTicks = 0;
  var seeking = false;
  var seekGen = 0;
  var eventCursor = 0;
  var feedLines = [];
  var goalsSeen = {};
  var goalTicks = [];
  var replayState = null; // instant-replay state machine
  var started = false;
  var attempt = 0;
  var readyTold = false;

  function setStatus(text) {
    var el = $("status");
    if (el) el.textContent = text;
  }

  function fail(message) {
    setStatus("Replay failed: " + message);
    var el = $("status");
    if (el && !document.getElementById("loading-retry")) {
      var retry = document.createElement("button");
      retry.id = "loading-retry";
      retry.type = "button";
      retry.textContent = "Retry";
      retry.style.pointerEvents = "auto";
      retry.onclick = function () { load(); };
      el.appendChild(document.createTextNode(" "));
      el.appendChild(retry);
    }
    document.documentElement.setAttribute("data-replay-error", message);
    tell("error", message);
  }

  function fetchReplay(url) {
    // AbortController bounds the wait; a fetch that never answers (a dead
    // CDN edge, a proxy holding the socket) is otherwise indistinguishable
    // from a slow one, and the caption would say LOADING until the tab died.
    var controller = typeof AbortController === "function" ?
      new AbortController() : null;
    var timer = window.setTimeout(function () {
      if (controller) controller.abort();
    }, FETCH_TIMEOUT_MS);
    return fetch(url, controller ? { signal: controller.signal } : {})
      .then(function (response) {
        if (!response.ok) throw new Error("replay fetch " + response.status);
        return response.text();
      })
      .catch(function (error) {
        if (error && error.name === "AbortError") {
          throw new Error("replay fetch timed out after " +
            Math.round(FETCH_TIMEOUT_MS / 1000) + "s");
        }
        throw error;
      })
      .finally(function () { window.clearTimeout(timer); });
  }

  function decodeControls(doc) {
    var raw = window.atob(doc.controls_b64);
    var bytes = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
    if (bytes.length !== doc.tick_count * BYTES_PER_TICK) {
      throw new Error("controls are " + bytes.length + " bytes, expected " +
        (doc.tick_count * BYTES_PER_TICK));
    }
    return bytes;
  }

  function parseReplay(text) {
    var doc = JSON.parse(text);
    if (!doc || doc.protocol !== PROTOCOL) {
      throw new Error("bad protocol: " + (doc && doc.protocol));
    }
    if (!Number.isInteger(doc.tick_count) || doc.tick_count <= 0) {
      throw new Error("bad tick_count: " + doc.tick_count);
    }
    if (!Number.isInteger(doc.seed)) {
      throw new Error("seed is not an integer: " + doc.seed);
    }
    doc._controls = decodeControls(doc);
    doc.events = Array.isArray(doc.events) ? doc.events : [];
    return doc;
  }

  // -- chrome ---------------------------------------------------------------

  var TEAM_CSS = ["hsl(202, 70%, 60%)", "hsl(342, 70%, 62%)"];

  function mmss(ticks) {
    var s = Math.max(0, Math.floor(ticks / TICKS_PER_SECOND));
    var m = Math.floor(s / 60);
    return (m < 10 ? "0" : "") + m + ":" +
      ((s % 60) < 10 ? "0" : "") + (s % 60);
  }

  function initChrome() {
    // textContent only: player names are player-controlled data.
    $("chip-a").style.background = TEAM_CSS[0];
    $("chip-b").style.background = TEAM_CSS[1];
    $("name-a").textContent = replay.names.players[0];
    $("name-b").textContent = replay.names.players[1];
    $("name-a").style.color = TEAM_CSS[0];
    $("name-b").style.color = TEAM_CSS[1];
    $("seek").max = totalTicks;
    goalTicks = replay.events
      .filter(function (e) { return e.type === "goal"; })
      .map(function (e) { return e.t; });
  }

  function pushFeed(text, cls) {
    feedLines.push({ text: text, cls: cls || "" });
    if (feedLines.length > 6) feedLines.shift();
    var feed = $("feed");
    feed.textContent = "";
    feedLines.forEach(function (line) {
      var div = document.createElement("div");
      div.className = line.cls;
      div.textContent = line.text;   // textContent: coach text is model data
      feed.appendChild(div);
    });
  }

  function alias(seat) { return replay.names.aliases[seat]; }

  function describe(ev) {
    switch (ev.type) {
      case "goal":
        return {
          text: "GOAL " + alias(ev.seat) + " \u2014 " + (ev.scorer || "?") +
            (ev.assist ? " (assist " + ev.assist + ")" : "") + ", " +
            ev.ball_speed + " m/s  [" + ev.score_after.join("\u2013") + "]",
          cls: "goal"
        };
      case "save":
        return { text: ev.robot + " saves it", cls: "save" };
      case "shot":
        return {
          text: ev.robot + (ev.on_target ? " shoots on target" : " drags it wide"),
          cls: ""
        };
      case "pass_completed":
        return { text: ev.from + " finds " + ev.to, cls: "" };
      case "interception":
        return { text: ev.robot + " reads it and intercepts", cls: "" };
      case "post":
        return { text: "off the post!", cls: "" };
      case "directive": {
        var says = (ev.robots || [])
          .map(function (r) { return r.say; })
          .filter(function (s) { return s; });
        var body = ev.note || says[0] || "";
        if (!body) return null;
        return {
          text: alias(ev.seat) + " coach: " + body +
            (ev.source === "llm" ? "" : " (" + ev.source + ")"),
          cls: "coach"
        };
      }
      case "fallback":
        return {
          text: alias(ev.seat) + " coach fell back (" + ev.cause + ")",
          cls: ""
        };
      default:
        return null;
    }
  }

  function replayEventsTo(tick) {
    while (eventCursor < replay.events.length &&
           replay.events[eventCursor].t <= tick) {
      var ev = replay.events[eventCursor++];
      var line = describe(ev);
      if (line) pushFeed(line.text, line.cls);
      if (ev.type === "goal") flashBanner(ev);
    }
  }

  function rewindEvents(tick) {
    eventCursor = 0;
    feedLines = [];
    $("feed").textContent = "";
    while (eventCursor < replay.events.length &&
           replay.events[eventCursor].t <= tick) {
      eventCursor++;
    }
  }

  var bannerTimer = null;
  function flashBanner(ev) {
    var banner = $("goalbanner");
    banner.textContent = "GOAL!";
    banner.style.color = TEAM_CSS[ev.seat];
    banner.classList.add("on");
    if (bannerTimer) window.clearTimeout(bannerTimer);
    bannerTimer = window.setTimeout(function () {
      banner.classList.remove("on");
    }, 1600);
  }

  function scoreAt(tick) {
    var score = [0, 0];
    for (var i = 0; i < replay.events.length; i++) {
      var ev = replay.events[i];
      if (ev.type !== "goal") continue;
      if (ev.t > tick) break;
      score = ev.score_after;
    }
    return score;
  }

  // -- instant slow-motion goal replay --------------------------------------
  //
  // Built purely out of viewer_seek / viewer_set_speed: pause half a second
  // on the goal, jump back 90 ticks, play those three seconds at 0.25x with a
  // banner, then jump forward and resume at the speed the viewer was on.
  // Each goal replays once; any manual scrub cancels it.

  function maybeStartGoalReplay(tick) {
    if (replayState) return;
    for (var i = 0; i < goalTicks.length; i++) {
      var gt = goalTicks[i];
      if (goalsSeen[gt]) continue;
      if (tick >= gt && tick <= gt + 4) {
        goalsSeen[gt] = true;
        replayState = {
          phase: "pause",
          goalTick: gt,
          until: performance.now() + 500,
          savedSpeed: call("viewer_get_speed", "number")
        };
        call("viewer_set_playing", null, ["number"], [0]);
        var banner = $("goalbanner");
        banner.textContent = "GOAL REPLAY";
        banner.classList.add("on");
        return;
      }
    }
  }

  function stepGoalReplay(tick) {
    if (!replayState) return;
    if (replayState.phase === "pause") {
      if (performance.now() < replayState.until) return;
      var from = Math.max(0, replayState.goalTick - 90);
      call("viewer_seek", null, ["number"], [from]);
      rewindEvents(from);
      call("viewer_set_speed", null, ["number"], [25]);
      call("viewer_set_playing", null, ["number"], [1]);
      replayState.phase = "rolling";
      return;
    }
    if (replayState.phase === "rolling" && tick >= replayState.goalTick) {
      call("viewer_set_speed", null, ["number"], [replayState.savedSpeed]);
      call("viewer_seek", null, ["number"], [replayState.goalTick]);
      rewindEvents(replayState.goalTick);
      call("viewer_set_playing", null, ["number"], [1]);
      $("goalbanner").classList.remove("on");
      replayState = null;
    }
  }

  function cancelGoalReplay() {
    if (!replayState) return;
    call("viewer_set_speed", null, ["number"], [replayState.savedSpeed]);
    $("goalbanner").classList.remove("on");
    replayState = null;
  }

  // -- wasm plumbing --------------------------------------------------------

  function call(name, ret, args, vals) {
    return window.Module.ccall(name, ret, args || [], vals || []);
  }

  function endcardText() {
    var r = replay.results || {};
    var who = r.winner === 0 ? alias(0) + " wins"
      : r.winner === 1 ? alias(1) + " wins" : "draw";
    return who + " " + (r.goals || [0, 0]).join("\u2013") +
      " (" + (r.end_rule || r.reason || "") + ")";
  }

  function refreshUi() {
    var tick = call("viewer_tick", "number");
    var playing = call("viewer_playing", "number");
    var score = scoreAt(tick);
    replayEventsTo(tick);
    maybeStartGoalReplay(tick);
    stepGoalReplay(tick);

    $("goals-a").textContent = String(score[0]);
    $("goals-b").textContent = String(score[1]);
    $("bug-clock").textContent =
      mmss(tick) + " / " + mmss(totalTicks);
    $("bug-turn").textContent = "turn " +
      Math.min(Math.floor(tick / replay.turn_ticks) + 1,
               Math.ceil(totalTicks / replay.turn_ticks)) +
      "/" + Math.ceil(totalTicks / replay.turn_ticks);
    $("tickinfo").textContent = tick + " / " + totalTicks;
    if (!seeking) $("seek").value = tick;
    var ended = !playing && tick >= totalTicks && totalTicks > 0;
    $("playpause").textContent = playing ? "pause" : (ended ? "replay" : "play");
    $("endcard").textContent = ended ? endcardText() : "";
    if (!readyTold) {
      readyTold = true;
      // The renderer draws on its own animation frame; report ready one
      // frame later so "ready" means a picture, not merely a parsed payload.
      window.requestAnimationFrame(function () {
        window.requestAnimationFrame(function () { tell("ready"); });
      });
    }
    window.requestAnimationFrame(refreshUi);
  }

  function start(text) {
    replay = parseReplay(text);
    totalTicks = replay.tick_count;
    initChrome();

    var builtSha = window.SIM_CORE_SHA256;
    var replaySha = replay.sim_core_sha256;
    if (builtSha && replaySha && replaySha !== "unknown" &&
        builtSha !== replaySha) {
      $("warn").textContent =
        "warning: this replay was recorded with a different sim build " +
        "(replay " + replaySha.slice(0, 12) + "\u2026 vs viewer " +
        builtSha.slice(0, 12) + "\u2026); re-simulation may diverge";
    }

    var bytes = replay._controls;
    var ptr = window.Module._malloc(bytes.length);
    window.Module.HEAPU8.set(bytes, ptr);
    var got = call("viewer_load", "number",
      ["number", "number", "number", "number"],
      [ptr, bytes.length, replay.seed >>> 0, replay.first_kickoff_seat | 0]);
    if (got < 0) throw new Error("viewer_load rejected the action log");
    if (got !== totalTicks) {
      throw new Error("action log has " + got + " ticks, document says " +
        totalTicks);
    }

    document.documentElement.removeAttribute("data-replay-error");
    setStatus("");
    ["playpause", "speed", "seek", "heat"].forEach(function (id) {
      $(id).disabled = false;
    });
    call("viewer_set_playing", null, ["number"], [1]);
    if (!started) {
      started = true;
      refreshUi();
    }
  }

  function load() {
    var url = new URLSearchParams(location.search).get("replay") ||
      "/replay-data";
    attempt += 1;
    document.documentElement.removeAttribute("data-replay-error");
    setStatus(attempt > 1 ? "retrying replay\u2026 (attempt " + attempt + ")"
                          : "fetching replay\u2026");
    fetchReplay(url)
      .then(function (text) { start(text); })
      .catch(function (error) {
        fail(String((error && error.message) || error));
      });
  }

  // -- transport ------------------------------------------------------------

  function wireControls() {
    $("playpause").addEventListener("click", function () {
      cancelGoalReplay();
      if (call("viewer_playing", "number")) {
        call("viewer_set_playing", null, ["number"], [0]);
        return;
      }
      if (call("viewer_tick", "number") >= totalTicks) {
        call("viewer_seek", null, ["number"], [0]);
        rewindEvents(0);
        goalsSeen = {};
      }
      call("viewer_set_playing", null, ["number"], [1]);
    });

    $("speed").addEventListener("change", function (e) {
      cancelGoalReplay();
      call("viewer_set_speed", null, ["number"], [Number(e.target.value)]);
    });

    $("heat").addEventListener("click", function () {
      var on = $("heat").textContent.indexOf("on") < 0;
      call("viewer_set_heat", null, ["number"], [on ? 1 : 0]);
      $("heat").textContent = "heat: " + (on ? "on" : "off");
    });

    // Seek re-simulates from tick 0 (deterministic, but not free): preview
    // while dragging, re-sim once on release. A drag that ends where it
    // started fires no `change`, so pointerup/keyup clear the preview too.
    $("seek").addEventListener("input", function (e) {
      seeking = true;
      $("tickinfo").textContent = e.target.value + " / " + totalTicks;
    });
    var endPreview = function () { seeking = false; };
    $("seek").addEventListener("pointerup", endPreview);
    $("seek").addEventListener("keyup", endPreview);
    $("seek").addEventListener("change", function (e) {
      var target = Number(e.target.value);
      var gen = ++seekGen;
      cancelGoalReplay();
      seeking = true;
      setStatus("seeking to tick " + target + " \u2026");
      window.setTimeout(function () {
        if (gen !== seekGen) return;   // superseded by a newer seek
        call("viewer_seek", null, ["number"], [target]);
        rewindEvents(target);
        setStatus("");
        seeking = false;
      }, 20);
    });
  }

  window.Module = {
    canvas: $("canvas"),
    onRuntimeInitialized: function () {
      wireControls();
      load();
    },
    printErr: function (t) { console.error(t); },
    // Runtime death must be visible on the page, not only in the console.
    onAbort: function (what) { fail("viewer wasm aborted: " + what); },
    onExit: function (code) {
      if (code !== 0) fail("viewer wasm exited: " + code);
    }
  };
})();
