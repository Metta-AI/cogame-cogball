// Public allowlist only. No codec/config/chat/provider state reaches the DOM.
const canvas = document.getElementById('canvas');
let playing = false, ready = false, frames = 0, lastStep = 0;
function inspect() { return JSON.parse(Module.UTF8ToString(Module._cogball_browser_state())); }
function draw() {
  if (!ready) return;
  const bounds = canvas.getBoundingClientRect();
  canvas.width = Math.max(1, Math.round(bounds.width));
  canvas.height = Math.max(1, Math.round(bounds.height));
  if (Module._cogball_browser_draw(canvas.width, canvas.height) !== 1)
    throw Error('Presentation changed authority state');
  frames++;
  const view = inspect();
  document.getElementById('status').textContent =
    `Tick ${view.tick} · ${view.phase} · Azure ${view.score[0]} – ${view.score[1]} Crimson`;
  return view;
}
function pause() { playing = false; return inspect(); }
function seek(tick) { pause(); Module._cogball_browser_seek(tick); return draw(); }
var Module = {
  canvas,
  printErr: text => { document.documentElement.dataset.replayError = text; },
  onRuntimeInitialized() { setTimeout(() => {
    ready = true;
    window.cogballReplay = {inspect, draw, seek, pause,
      play() { playing = true; lastStep = performance.now(); },
      stats() { return {playing, frames, width:canvas.width, height:canvas.height}; },
      negative() { return Module._cogball_browser_negative() === 1; }};
    for (const id of ['play', 'pause', 'seek']) document.getElementById(id).disabled = false;
    draw();
  }, 0); }
};
document.getElementById('play').onclick = () => window.cogballReplay.play();
document.getElementById('pause').onclick = () => pause();
document.getElementById('seek').onclick = () => seek(Number(document.getElementById('tick').value));
window.addEventListener('resize', draw);
function frame(now) {
  if (ready && playing && now - lastStep >= 1000 / 24) {
    lastStep = now;
    if (Module._cogball_browser_step() === 0) playing = false;
    draw();
  }
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
