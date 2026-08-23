#!/usr/bin/env node
'use strict';
// Execute a static replay-bundle page's scripts in a DOM-less harness and fail
// if the shell dies on the way to starting the replay.
//
// WHY THIS EXISTS. `tests/test_viewer.nim` asserts the shell's TEXT (every
// control id, every readout, the density rules) and `wasm_replay_smoke.cjs`
// drives the wasm core directly — neither one ever EXECUTES the page's inline
// script. So cogball 0.1.3 shipped a bundle whose shell threw
// `ReferenceError: COG_BASE is not defined` on line 1 of the locker-room IIFE,
// aborting everything after it (including `createCore(...).start()`), with the
// whole test suite green: every asset fetched 200, the wasm was fine, and the
// viewer showed a black stage forever.
//
// The harness runs each <script> of the page in order inside a `vm` context
// whose global is a Proxy over a stubbed browser, and reports:
//   1. every identifier the page READS that nothing ever defined (the
//      ReferenceError class, all of them, not just the first — the proxy
//      returns an inert stub so execution continues),
//   2. any exception escaping a script,
//   3. for the board page, whether the shell reached `core.start()` — proven
//      by `data-replay-worker`, which static_replay.js sets only after the
//      Worker is constructed and handed the replay URL.
//
// Usage: node tools/ci/viewer_shell_check.cjs <bundle-dir> [page.html ...]
//        (default pages: index.html league.html)

const fs = require('fs');
const path = require('path');
const vm = require('vm');

// ---------------------------------------------------------------- DOM stubs
function makeStyle() {
  const decl = {
    setProperty() {},
    removeProperty() {},
    getPropertyValue() { return ''; }
  };
  return new Proxy(decl, {
    get(target, prop) {
      if (prop in target) return target[prop];
      return '';
    },
    set(target, prop, value) { target[prop] = value; return true; }
  });
}

function makeContext2d(canvas) {
  const gradient = { addColorStop() {} };
  const ctx = {
    canvas,
    // state the shell reads back
    fillStyle: '#000', strokeStyle: '#000', lineWidth: 1, globalAlpha: 1,
    globalCompositeOperation: 'source-over', font: '10px sans-serif',
    textAlign: 'start', textBaseline: 'alphabetic', lineCap: 'butt',
    lineJoin: 'miter', shadowBlur: 0, shadowColor: 'transparent',
    imageSmoothingEnabled: true, filter: 'none', miterLimit: 10,
    measureText() { return { width: 0, actualBoundingBoxAscent: 0, actualBoundingBoxDescent: 0 }; },
    createLinearGradient() { return gradient; },
    createRadialGradient() { return gradient; },
    createPattern() { return {}; },
    getImageData(x, y, w, h) {
      const width = Math.max(1, w | 0), height = Math.max(1, h | 0);
      return { width, height, data: new Uint8ClampedArray(width * height * 4) };
    },
    createImageData(w, h) { return ctx.getImageData(0, 0, w, h); },
    getTransform() { return { a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 }; },
    isPointInPath() { return false; }
  };
  const noops = ['save', 'restore', 'scale', 'rotate', 'translate', 'transform',
    'setTransform', 'resetTransform', 'clearRect', 'fillRect', 'strokeRect',
    'beginPath', 'closePath', 'moveTo', 'lineTo', 'bezierCurveTo',
    'quadraticCurveTo', 'arc', 'arcTo', 'ellipse', 'rect', 'roundRect', 'fill',
    'stroke', 'clip', 'fillText', 'strokeText', 'drawImage', 'putImageData',
    'setLineDash', 'drawFocusIfNeeded'];
  for (const name of noops) ctx[name] = function () {};
  ctx.getLineDash = function () { return []; };
  return ctx;
}

function makeElement(doc, tag) {
  const attrs = new Map();
  const el = {
    ownerDocument: doc,
    nodeType: 1,
    tagName: String(tag || 'div').toUpperCase(),
    style: makeStyle(),
    dataset: {},
    children: [],
    childNodes: [],
    firstChild: null,
    lastChild: null,
    parentNode: null,
    parentElement: null,
    nextSibling: null,
    previousSibling: null,
    offsetParent: null,
    id: '', className: '', textContent: '', innerHTML: '', innerText: '',
    title: '', alt: '', src: '', href: '', value: '', type: '', name: '',
    complete: false, naturalWidth: 0, naturalHeight: 0,
    checked: false, disabled: false, hidden: false, tabIndex: 0,
    width: 0, height: 0,
    offsetWidth: 0, offsetHeight: 0, offsetLeft: 0, offsetTop: 0,
    clientWidth: 0, clientHeight: 0, clientLeft: 0, clientTop: 0,
    scrollWidth: 0, scrollHeight: 0, scrollTop: 0, scrollLeft: 0,
    classList: {
      add() {}, remove() {}, toggle() {}, contains() { return false; },
      replace() {}
    },
    setAttribute(key, value) { attrs.set(String(key), String(value)); },
    getAttribute(key) {
      const k = String(key);
      return attrs.has(k) ? attrs.get(k) : null;
    },
    removeAttribute(key) { attrs.delete(String(key)); },
    hasAttribute(key) { return attrs.has(String(key)); },
    appendChild(child) {
      el.children.push(child);
      el.childNodes.push(child);
      el.firstChild = el.childNodes[0];
      el.lastChild = child;
      if (child) { child.parentNode = el; child.parentElement = el; }
      return child;
    },
    append(...nodes) { for (const n of nodes) el.appendChild(n); },
    prepend() {},
    insertBefore(child) { return el.appendChild(child); },
    removeChild(child) {
      el.children = el.children.filter((c) => c !== child);
      el.childNodes = el.childNodes.filter((c) => c !== child);
      el.firstChild = el.childNodes[0] || null;
      return child;
    },
    replaceChildren() { el.children = []; el.childNodes = []; el.firstChild = null; },
    remove() {},
    cloneNode() { return makeElement(doc, tag); },
    contains() { return false; },
    closest() { return null; },
    matches() { return false; },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    getElementsByTagName() { return []; },
    getElementsByClassName() { return []; },
    addEventListener() {}, removeEventListener() {}, dispatchEvent() { return true; },
    focus() {}, blur() {}, click() {}, scrollIntoView() {},
    setPointerCapture() {}, releasePointerCapture() {},
    getBoundingClientRect() {
      return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 };
    },
    animate() { return { cancel() {}, finish() {}, addEventListener() {} }; },
    getContext() { return makeContext2d(el); },
    // static_replay.js only starts the Worker when the board canvas can hand
    // over an OffscreenCanvas, so the stub must support it or the harness
    // would "pass" a shell that never starts.
    transferControlToOffscreen() { return { width: 0, height: 0 }; },
    toDataURL() { return 'data:,'; },
    play() { return Promise.resolve(); },
    pause() {},
    decode() { return Promise.resolve(); }
  };
  return el;
}

function makeDocument(pageUrl) {
  const doc = {};
  const documentElement = makeElement(doc, 'html');
  const body = makeElement(doc, 'body');
  const head = makeElement(doc, 'head');
  const cache = new Map();
  Object.assign(doc, {
    nodeType: 9,
    documentElement,
    body,
    head,
    title: '',
    hidden: false,
    visibilityState: 'visible',
    readyState: 'complete',
    currentScript: { src: pageUrl },
    // One element per id, so a handler that stashes $('x') sees the same object
    // the wiring code did.
    getElementById(id) {
      const key = String(id);
      if (!cache.has(key)) {
        const el = makeElement(doc, 'div');
        el.id = key;
        cache.set(key, el);
      }
      return cache.get(key);
    },
    createElement(tag) { return makeElement(doc, tag); },
    createElementNS(ns, tag) { return makeElement(doc, tag); },
    createTextNode(text) { return { nodeType: 3, textContent: String(text) }; },
    createDocumentFragment() { return makeElement(doc, 'fragment'); },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    getElementsByTagName() { return []; },
    getElementsByClassName() { return []; },
    addEventListener() {}, removeEventListener() {}, dispatchEvent() { return true; },
    execCommand() { return false; },
    exitFullscreen() { return Promise.resolve(); },
    fullscreenElement: null,
    activeElement: body,
    cookie: ''
  });
  return doc;
}

// An inert value for a global nothing defined: callable, indexable, and
// coercible, so one missing name is REPORTED rather than aborting the page and
// hiding every name after it.
function makeInertStub(name) {
  const target = function () {};
  const proxy = new Proxy(target, {
    get(t, prop) {
      if (prop === Symbol.toPrimitive) {
        return (hint) => (hint === 'number' ? 0 : '');
      }
      if (prop === Symbol.iterator) return undefined;
      if (prop === 'toString') return () => '';
      if (prop === 'valueOf') return () => 0;
      if (prop === 'name') return name;
      if (prop === 'length') return 0;
      return proxy;
    },
    set() { return true; },
    apply() { return proxy; },
    construct() { return proxy; },
    has() { return true; }
  });
  return proxy;
}

// ------------------------------------------------------------------ harness
function runPage(dir, page) {
  const file = path.join(dir, page);
  const html = fs.readFileSync(file, 'utf8');
  const pageUrl = 'https://viewer.invalid/static/' + page;
  const doc = makeDocument(pageUrl);

  const workers = [];
  const missing = new Map();   // name -> first read
  const errors = [];

  function Worker(url, options) {
    const worker = {
      url: String(url),
      name: (options && options.name) || '',
      onmessage: null, onerror: null, onmessageerror: null,
      postMessage() {}, terminate() {}, addEventListener() {}, removeEventListener() {}
    };
    workers.push(worker);
    return worker;
  }

  const globals = {
    document: doc,
    location: {
      href: pageUrl + '?replay=https%3A%2F%2Fexample.invalid%2Fr.replay',
      pathname: '/static/' + page,
      search: '?replay=https%3A%2F%2Fexample.invalid%2Fr.replay',
      hash: '', host: 'viewer.invalid', hostname: 'viewer.invalid',
      origin: 'https://viewer.invalid', protocol: 'https:', port: '',
      reload() {}, replace() {}, assign() {}, toString() { return this.href; }
    },
    navigator: { userAgent: 'viewer-shell-check', language: 'en-US', platform: 'linux', maxTouchPoints: 0, clipboard: { writeText() { return Promise.resolve(); } } },
    history: { pushState() {}, replaceState() {}, back() {}, forward() {} },
    devicePixelRatio: 1,
    innerWidth: 1280, innerHeight: 720, outerWidth: 1280, outerHeight: 720,
    scrollX: 0, scrollY: 0,
    Worker,
    Image: function Image() { return makeElement(doc, 'img'); },
    Audio: function Audio() { return makeElement(doc, 'audio'); },
    WebSocket: function WebSocket() {
      return { readyState: 0, send() {}, close() {}, addEventListener() {} };
    },
    ResizeObserver: function ResizeObserver() {
      return { observe() {}, unobserve() {}, disconnect() {} };
    },
    IntersectionObserver: function IntersectionObserver() {
      return { observe() {}, unobserve() {}, disconnect() {} };
    },
    MutationObserver: function MutationObserver() {
      return { observe() {}, disconnect() {}, takeRecords() { return []; } };
    },
    OffscreenCanvas: function OffscreenCanvas() { return makeElement(doc, 'canvas'); },
    getComputedStyle() { return makeStyle(); },
    matchMedia() { return { matches: false, addListener() {}, removeListener() {}, addEventListener() {} }; },
    // Timers never fire: this harness checks the page's SYNCHRONOUS boot, and
    // a firing timer would make the result depend on wall-clock scheduling.
    setTimeout() { return 0; },
    clearTimeout() {},
    setInterval() { return 0; },
    clearInterval() {},
    requestAnimationFrame() { return 0; },
    cancelAnimationFrame() {},
    queueMicrotask() {},
    fetch() { return new Promise(function () {}); },
    alert() {}, confirm() { return false; }, prompt() { return null; },
    scrollTo() {}, open() { return null; }, close() {}, focus() {}, blur() {},
    print() {},
    addEventListener() {}, removeEventListener() {}, dispatchEvent() { return true; },
    localStorage: {
      getItem() { return null; }, setItem() {}, removeItem() {}, clear() {}
    },
    sessionStorage: {
      getItem() { return null; }, setItem() {}, removeItem() {}, clear() {}
    },
    console,
    performance: { now: () => 0 },
    postMessage() {}
  };

  // The realm's own intrinsics (Object, Math, JSON, URL, URLSearchParams,
  // Promise, TextDecoder, atob, …) are legitimate globals; seed them so the
  // `has` trap below does not report them as undefined.
  for (const name of Object.getOwnPropertyNames(globalThis)) {
    if (!(name in globals)) {
      const value = globalThis[name];
      if (typeof value !== 'undefined') globals[name] = value;
    }
  }
  delete globals.global;
  delete globals.process;
  delete globals.require;
  delete globals.module;

  // `window` resolves unknown properties to undefined, exactly like a browser,
  // so feature detection (`if (window.ResizeObserver)`) is not a finding. Bare
  // identifiers go through the context proxy below, which DOES report.
  const windowProxy = new Proxy(globals, {
    get(target, prop) { return prop in target ? target[prop] : undefined; },
    set(target, prop, value) { target[prop] = value; return true; }
  });
  globals.window = windowProxy;
  globals.self = windowProxy;
  globals.top = windowProxy;
  globals.parent = windowProxy;
  globals.frameElement = null;

  const contextProxy = new Proxy(globals, {
    // Claim every name so an undefined global is COLLECTED instead of throwing
    // and hiding the rest of the page.
    has() { return true; },
    get(target, prop) {
      if (prop in target) return target[prop];
      if (typeof prop === 'symbol') return undefined;
      if (!missing.has(prop)) missing.set(prop, true);
      return makeInertStub(prop);
    },
    set(target, prop, value) { target[prop] = value; return true; },
    getOwnPropertyDescriptor(target, prop) {
      return Object.getOwnPropertyDescriptor(target, prop);
    }
  });
  vm.createContext(contextProxy);

  // Scripts in document order: <script src> is read from the bundle (a missing
  // file is a finding of its own), inline scripts run as written.
  const tagRe = /<script\b([^>]*)>([\s\S]*?)<\/script>/gi;
  let match, index = 0;
  while ((match = tagRe.exec(html)) !== null) {
    const attrs = match[1] || '';
    const srcMatch = attrs.match(/\bsrc\s*=\s*["']([^"']+)["']/i);
    let code, name;
    if (srcMatch) {
      const rel = srcMatch[1].replace(/^\.\//, '');
      const scriptPath = path.join(dir, rel);
      if (!fs.existsSync(scriptPath)) {
        errors.push(page + ': <script src="' + srcMatch[1] + '"> is not in the bundle');
        continue;
      }
      code = fs.readFileSync(scriptPath, 'utf8');
      name = rel;
    } else {
      code = match[2];
      name = page + ' inline#' + (++index);
    }
    try {
      new vm.Script(code, { filename: name }).runInContext(contextProxy);
    } catch (error) {
      errors.push(name + ': ' + (error && error.stack ? error.stack.split('\n').slice(0, 3).join('\n    ') : error));
    }
  }

  return { doc, workers, missing: [...missing.keys()], errors };
}

// --------------------------------------------------------------------- main
const dir = process.argv[2];
const pages = process.argv.slice(3);
if (!dir) {
  console.error('usage: viewer_shell_check.cjs <bundle-dir> [page.html ...]');
  process.exit(2);
}
const wanted = pages.length ? pages : ['index.html', 'league.html'];

let failures = 0;
for (const page of wanted) {
  if (!fs.existsSync(path.join(dir, page))) {
    console.error('FAIL ' + page + ': not in ' + dir);
    failures++;
    continue;
  }
  const result = runPage(dir, page);
  const problems = [];
  for (const name of result.missing) {
    problems.push('reads `' + name + '`, which nothing in the page defines ' +
      '(a ReferenceError in a real browser)');
  }
  for (const error of result.errors) problems.push('threw: ' + error);
  // The board page must reach core.start(): static_replay.js sets
  // data-replay-worker only once the Worker exists and has the replay URL.
  if (page === 'index.html') {
    if (result.doc.documentElement.getAttribute('data-replay-worker') !== 'true') {
      problems.push('never reached core.start(): the shell finished without ' +
        'starting the replay Worker (data-replay-worker unset)');
    }
    if (result.workers.length !== 1) {
      problems.push('created ' + result.workers.length + ' replay Workers, expected 1');
    } else if (!/static_replay_worker\.js$/.test(result.workers[0].url)) {
      problems.push('started the wrong Worker: ' + result.workers[0].url);
    }
  }
  if (problems.length) {
    failures++;
    console.error('FAIL ' + page);
    for (const problem of problems) console.error('  - ' + problem);
  } else {
    console.log('ok   ' + page + ' — scripts executed, replay start reached');
  }
}

if (failures) {
  console.error('viewer_shell_check: ' + failures + ' page(s) failed');
  process.exit(1);
}
console.log('viewer_shell_check: every page boots');
