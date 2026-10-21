## The actual Polyworld ShapeRenderer API; engine source stays read-only.
import std/math
import chroma, vmath
import polyworld/shapes
import cogball/sim_types
import snapshot

proc position(body: BodyView): Vec3 =
  vec3(body.x.float32 / 1_000_000 - 22, 0, body.y.float32 / 1_000_000 - 12.5)

proc digit(renderer: var ShapeRenderer, number: int32, x: float32, color: ColorRGBX) =
  const segments = [0b1111110, 0b0110000, 0b1101101, 0b1111001, 0b0110011,
    0b1011011, 0b1011111, 0b1110000, 0b1111111, 0b1111011]
  # a,b,c,d,e,f,g: a compact seven-segment score above the pitch.
  let ends = [(-0.5'f32,-1'f32,0.5'f32,-1'f32),
    (0.5'f32,-1'f32,0.5'f32,0'f32), (0.5'f32,0'f32,0.5'f32,1'f32),
    (-0.5'f32,1'f32,0.5'f32,1'f32), (-0.5'f32,0'f32,-0.5'f32,1'f32),
    (-0.5'f32,-1'f32,-0.5'f32,0'f32), (-0.5'f32,0'f32,0.5'f32,0'f32)]
  for i, e in ends:
    if (segments[int(number mod 10)] and (1 shl (6-i))) != 0:
      renderer.addLine(vec3(x+e[0],0,-15+e[1]), vec3(x+e[2],0,-15+e[3]), color, 0.1)

proc addScene*(renderer: var ShapeRenderer, view: ReplayView) =
  for score in view.score:
    doAssert score in 0'i32..9'i32, "prototype score display supports 0..9"
  let white = rgbx(235,240,235,255)
  let azure = rgbx(40,145,255,255)
  let crimson = rgbx(255,65,95,255)
  renderer.clear()
  renderer.addQuad(vec3(-22,0,-12.5),vec3(22,0,-12.5),
    vec3(22,0,12.5),vec3(-22,0,12.5),rgbx(30,100,55,255))
  renderer.addPolyline([vec3(-20,0,-12.5),vec3(20,0,-12.5),
    vec3(20,0,12.5),vec3(-20,0,12.5),vec3(-20,0,-12.5)],white,0.06)
  renderer.addLine(vec3(0,0,-12.5),vec3(0,0,12.5),white,0.05)
  # Exactly six fixed robot slots, not the two private policy seats.
  for i, robot in view.robots:
    let p = position(robot)
    let color = if i < RobotsPerSeat: azure else: crimson
    renderer.addCircle(p, RobotRadius.float32 / 1_000_000, color)
    let angle = robot.heading.float32 * 2 * PI.float32 / HeadingQTurn.float32
    renderer.addLine(p,p+vec3(cos(angle)*0.7,0,sin(angle)*0.7),white,0.06)
  renderer.addCircle(position(view.ball),BallRadius.float32 / 1_000_000,white)
  renderer.digit(view.score[0],-3,azure)
  renderer.digit(view.score[1],3,crimson)

proc overheadProjection*(): Mat4 =
  ## Map world XZ to screen XY. No camera state can reach the simulation.
  result[0,0] = 1'f32 / 24
  result[2,1] = -1'f32 / 18
  result[1,2] = 0.01
  result[3,3] = 1
