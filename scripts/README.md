# scripts/

Index only. How to use them: `docs/BUILD.md` and `docs/BENCH.md`. Why they work
the way they do: `docs/adr/`.

| Script | Role |
|---|---|
| `pick-build-host.sh` | claims a free Intel Lion mini (`--status`, `--acquire LABEL`, `--release HOST`). The lock lives ON the host, so it sees builds other repos and agents started. ADR 0005 |
| `build.sh <g3\|g4\|g5\|lion>` | one slice. Wipes its output dir, `make clean`s remotely, then **asserts and re-stamps the cpusubtype**. ADR 0001, ADR 0006 |
| `build-fat.sh` | g3→g4→g5→lion sequentially on ONE pinned host, then `lipo`. The only supported way to produce `build/q2-fat` |
| `deploy.sh <machine>` | ships the fat `Quake2.app` plus the loose `ref_gl.so` / `q2ded` / `baseq2/game.so`; md5-verifies what landed |
| `make-dmg.sh` | stages the image, runs `hdiutil create -format UDZO` on a **Tiger** box, then mounts the result and md5s every binary inside it against source. ADR 0005, ADR 0006 |
| `deploy-dmg.sh <machine>` | installs from the mounted image the way a human does; md5-verifies each installed binary, retries 4x, exits 7 on failure |
| `smoke-dmg.sh <machine>` | launches the installed copy with the PRODUCTION config and a timedemo so it auto-exits. ADR 0009 |
| `bench.sh <machine> <demo> <WxH> [runs]` | timedemo harness. Rejects a malformed resolution; refuses a non-native fullscreen on `imac-g5`; TERM-sleep-KILL always |
| `parallel-bench.sh` | fleet grid; refuses to run both `yosemite` partitions |
| `bench-and-commit.sh` | lands official `benchmarks/results.csv` rows on a clean tree |
| `screenshot.sh` | visual A/B captures; same G5 safety rails as `bench.sh` |
| `analyze.sh` | static-analysis pass over the engine tree |
| `build-server-linux.sh` | Linux `q2ded` + `game.so` in a Debian 11 container (`--arch x86_64\|aarch64`). ADR 0011 |
| `docker/server-build.Dockerfile` | that container |
| `gen-decals.py` | generates every decal and shadow TGA. ADR 0012 |
| `make-icon.py` | legacy-only ICNS pipeline. ADR 0012 |
| `watchlink-listen.py` | desktop receiver for the UDP player-state feed. `docs/WATCHLINK.md` |
| `bundle/` | static assets and the autoexec layer staged into the `.app` |
| `tidy-quicksilver.sh` | proposed cleanup of quicksilver's existing Q2 install. **Do not run without the user's confirmation** — it deletes the legacy 1999 Mac binaries, which are not reusable but are still the user's property. It keeps `Q2DedicatedServer`, the 2006 PPC OS X server build |
