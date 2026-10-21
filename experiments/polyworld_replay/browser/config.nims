import std/os
let outputDir = getEnv("COGBALL_BROWSER_OUTPUT")
let replay = getEnv("COGBALL_BROWSER_REPLAY")
doAssert outputDir.len > 0 and replay.len > 0
let root = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
switch("threads", "off")
--os:linux
--cpu:wasm32
--cc:clang
--clang.exe:emcc
--clang.linkerexe:emcc
--mm:arc
--exceptions:goto
--define:noSignalHandler
--define:useMalloc
--define:release
--define:noAutoGLerrorCheck
switch("out", outputDir / "cogball_browser.js")
switch("nimcache", outputDir.parentDir() / "browser-cache")
switch("passL", "-O2 --preload-file " & quoteShell(root / "data" & "@/data") &
  " --preload-file " & quoteShell(replay & "@/public.bitreplay") &
  " -s ALLOW_MEMORY_GROWTH -s MAXIMUM_MEMORY=268435456 -s ABORTING_MALLOC=1" &
  " -s ENVIRONMENT=web -s EXIT_RUNTIME=0 -s USE_WEBGL2=1 -s MIN_WEBGL_VERSION=2" &
  " -s MAX_WEBGL_VERSION=2 -s FULL_ES3=1 -s GL_ENABLE_GET_PROC_ADDRESS=1" &
  " -s EXPORTED_RUNTIME_METHODS=UTF8ToString" &
  " -s EXPORTED_FUNCTIONS=_main,_cogball_browser_state,_cogball_browser_step," &
  "_cogball_browser_seek,_cogball_browser_draw,_cogball_browser_negative")
