## Bounded native presentation acceptance; supports CPU Mesa under Xvfb.
import std/[json, os, strutils]
import windy, opengl, pixie, flatty
import polyworld/shapes
import cogball/[replays,replay_runtime]
import snapshot, scene

var r = initReplayRuntime(parseReplayBytes(readFile(paramStr(1))),true,false)
r.player.seekReplay(r.sim,parseInt(paramStr(2)))
let before = toFlatty(r.sim)
let view = snapshot(r.sim)
let window = newWindow("Cogball Polyworld replay",ivec2(960,720),openglVersion=OpenGL3Dot3)
window.makeContextCurrent()
loadExtensions()
let backend = $cast[cstring](glGetString(GL_RENDERER))
doAssert "llvmpipe" in backend or "softpipe" in backend,
  "This proof requires software rendering: " & backend
var renderer = initShapeRenderer()
for i in 0..2:
  glViewport(0,0,960,720)
  glClearColor(0.025,0.03,0.05,1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  renderer.addScene(view)
  renderer.draw(overheadProjection())
  glFinish()
  doAssert toFlatty(r.sim) == before
let image = newImage(960,720)
glReadPixels(0,0,960,720,GL_RGBA,GL_UNSIGNED_BYTE,image.data[0].addr)
image.flipVertical()
image.writeFile(paramStr(3))
writeFile(paramStr(4),$(%*{"renderer":backend,"state":view.publicJson(),
  "authorityUnchanged":true,"presentationFrames":3}))
renderer.closeShapeRenderer()
window.close()
