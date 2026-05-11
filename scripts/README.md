# scripts/

Build/deploy/bench scaffolding for the yquake2 PPC port. **Adapted
from `~/quakespasm/scripts/`** — read those originals as templates.
Don't reinvent.

## Status: pre-Phase-A

Scripts will be ported as Phase A.1 / A.2 / A.4 land. Until then this
directory holds:

- `tidy-quicksilver.sh` — proposed cleanup of `quicksilver:~/Desktop/Quake 2/`
  (the user's existing Q2 install) into a clean game-data layout.
  **Do not run without user confirmation** — it deletes the legacy
  1999/2006 Mac binaries that aren't reusable but are still the user's
  property.

## To adapt from QuakeSpasm (Phase A.1)

| QuakeSpasm script | Q2 adaptation |
|---|---|
| `build.sh <g3\|g4\|lion>` | Same shape. Engine source at `yquake2/` top-level. Different makefile (yquake2/Makefile, not Quake/Makefile.darwin). Override `OSX_ARCH`, `CFLAGS`, `LDFLAGS` for cross-targets. Disable WITH_OGG/OPENAL/CDA for Phase A. |
| `deploy.sh <machine>` | Same shape. Bundle layout differs slightly: yquake2 ships ref_gl.so as either a dlopen plugin or linked-in depending on `OSX_APP` makefile target — investigate before writing. Reuse `~/quakespasm/MacOSX/SDL.framework` byte-for-byte. |
| `bench.sh <machine> <demo> <res>` | Same shape. Q2 demo names have `.dm2` suffix (`+timedemo demo1.dm2`). Timedemo output format differs — adapt parse_qconsole.py. |
| `parallel-bench.sh` | Same shape, no Q1-specific assumptions to fix. |
| `bench-and-commit.sh` | Same shape, no changes needed. |
| `full-bench.sh` | Same shape. |
| `setup-lion.sh` | **Probably not needed** — mini-intel is already set up from QuakeSpasm. Re-verify gcc-4.0 + 10.3.9/10.4u SDKs are still installed. |
| `install-host-tools.sh` | **Not needed** — qsreboot.sh already on every bench Mac. |
| `build-fat.sh` + `lipo` | **Defer to Phase B** at earliest. Get per-target builds working first. |
| `host-bin/qsreboot.sh` | Already deployed on every Mac. Reuse via SSH. |
| `bundle/autoexec-<machine>.cfg` | Q2-flavored per-machine configs — populate as Phase C lands. |

## Cross-references in `~/quakespasm/CLAUDE.md` to consult

- "Tooling — DON'T reinvent these inline" — the scripts contract
- "Hosts" — SSH alias table
- "Bench-and-commit cadence" — the commit/bench discipline
- "How the fat SDL was built" — for future SDL framework changes
- "Required patches for our target build" — patch class to expect
