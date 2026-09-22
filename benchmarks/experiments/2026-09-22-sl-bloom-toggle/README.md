# #70: bloom toggled on mid-session, Snow Leopard, 2026-09-22

The one trigger #70 left untested: bloom starts off, then `gl_bloom 1` is set
during play. That makes `R_Bloom()` create its textures lazily inside the
render loop, instead of at cold `R_Init`.

- Host: mini-sl, Macmini3,1, Mac OS X 10.6.8, NVIDIA GeForce 9400, under a
  `pick-bench-host.sh --run mini-sl` claim, system output muted.
- Binary: the installed v2.12.0 release (engine `2f7874ddbd9f78498d35dce1b107aa38`,
  `ref_gl.so` `b048e080987ec664bb6ae23831ed4ee7`, x86_64 slice), production
  bundle cfgs, 1024x768.
- `+set gl_bloom 0` on the command line. Without it the x86_64 baseline's
  `gl_bloom -1` auto-enables bloom on this measured GPU at launch, which is
  what a first attempt did by mistake. It was discarded as not exercising the
  toggle.
- `timedemo demo1`, then from a cfg: 250 waits, screenshot, `set gl_bloom 1`,
  120 waits, screenshot, quit. Script: `run-on-mini-sl.sh`.

## Result: PASS, no stall

- The log has no `bloom auto` line, so bloom was off at `R_Init`. Shot 1 was
  written, then `Bloom GL diagnostics: read 0x405, draw 0x405, capture 0x0,
  downsample 0x0, darken 0x0, blur-x 0x0, blur-y 0x0, composite 0x0`, then
  shot 2 (`qconsole.log` lines 149-151).
- The engine quit by itself 8 s after launch (`driver.log`). The first attempt
  also exited by itself, after 10 s.
- `bloom-on-after-toggle.png` shows the rendered scene after the lazy init. The
  two shots are different demo frames, so they are not a pixel comparison.
