# #79 capability probe on mapped and unmapped hardware, 2026-09-22

Candidate: `dist/Quake2-OldMac-885f7de8.dmg`, engine md5 `a035bd5d…`, source
stamp `a354a0bb`. Baseline: v2.12.0, engine md5 `2f7874dd…`.

Method: launch the installed engine with its production bundle config, plus
`+set logfile 2 +set s_initsound 0 +cvarlist +quit`, then diff the full
cvar lists.

## mini-g4 (mapped: PowerMac10,1, Radeon 9200, 10.4.11)

The candidate logs `...mapped machine, GPU matches its overlay (radeon 9200):
keeping the measured profile`. The v2.12.0 → candidate diff
(`mini-g4-cvar-diff.txt`) has four entries, and none of them is a profile
change:

- `q2_overlay_gpu "radeon 9200"` is new, #79's own declaration of the overlay's measured GPU.
- `qport` is randomised on every launch.
- `watch_enable "0"` is new in b881d21c.
- `g_select_empty` is registered by `game.so`, which never loads when the
  engine quits before a map. In the v2.12.0 run it came from `config.cfg`,
  and quitting rewrote `config.cfg` without it at 20:21 (checked on the
  host). Its default is 0 either way.

## workstation (unmapped: Apple M5, arm64, macOS 26.6.2)

The candidate ran from a scratch copy of the DMG, windowed, with the user's
`config.cfg` backed up and restored byte-identical. It logs `...capability
tier, unrecognised GPU: keeping the conservative baseline`, so the probe
still fires where no overlay exists. mini-sl, the planned unmapped Intel
check (GeForce 9400), was offline.
