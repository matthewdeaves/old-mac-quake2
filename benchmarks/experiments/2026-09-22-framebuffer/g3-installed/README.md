# Installed Panther shadow candidate

Exact artifact: `Quake2-OldMac-2026-09-22-shadows-rc1.dmg`.
The updater verified its signature, six CPU slices and runtime hashes, preserved
the baseq2 data and retained the previous installation in a named rollback.
See `install.log` for artifact digest, installed hashes and rollback location.

Jenkins `smoke-quake2-g3` build 4 passed the actual LaunchServices launch:
ATI Rage 128 renderer, 1024x768, map loaded. Panther does not accept `open --args`,
so this smoke checks map startup rather than a timedemo. The controller's G3
executor initially failed to launch with a Java spawn-helper error. All executor
slots were idle; restarting the Jenkins user service recovered the queued job.

The complete installed candidate then ran demo2 three times: 28.3 fps each.
Only the benchmark's normal timing/display/sound settings were forced; its extra
commands read back the effects without changing them. All raw logs confirm
gl_shadows=1, gl_stencilshadow=1, gl_clear_combined=1 and gl_ztrick=0.
This remains a sound-disabled benchmark, not an audio-enabled gameplay result.

`projected.png` is the installed candidate's inspected frame. The user also
reported that the shadows look good. The final check restored the normal-play
configuration and verified output volume 0 with output muted true. No game was
left running. Panther stays ready for the user's manual test; do not switch OS
or launch another G3 benchmark while it is handed over.
