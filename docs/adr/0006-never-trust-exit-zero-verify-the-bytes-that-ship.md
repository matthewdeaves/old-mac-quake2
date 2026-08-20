# 6. Never trust exit 0: verify the artifact, and verify the bytes that ship

Date: 2026-08-20 (records decisions taken 2026-05-31 and 2026-07-25)
Status: accepted

## Context

Every failure below actually happened to this project. An exit code of 0 is not
evidence that the thing you wanted got built, and a packaging pipeline that
reports success is not evidence that the bytes survived it.

## Decision

**Verify the property you care about on the artifact itself, at the last hop the
user runs.**

### 1. Wipe before building; a failed build is invisible otherwise

`build.sh` `rm -rf`s `build/q2-$TARGET` **before** fetching, and `make clean`s on
the build host. Without that, a failed build leaves the previous run's binaries
in place and every downstream check, `lipo`, `file`, even the cpusubtype
assertion, passes on an artifact nobody meant to ship. This bit on 2026-07-25:
`build/q2-g4` held an old-flags build after the fat had been linked, so the
per-target directory and the fat's member disagreed.

### 2. Prove the fat and the per-target dir agree

`build/q2-fat` must come from one `build-fat.sh` run. If you rebuild a single
slice afterwards they are different files:

    lipo -thin ppc7400 build/q2-fat/quake2 -output /tmp/m && md5sum /tmp/m build/q2-g4/quake2

**The PPC builds are not byte-reproducible**, roughly **138 bytes** of embedded
build metadata differ between two builds of identical source. So an md5 mismatch
across two separate runs proves nothing; only compare artifacts from the **same**
run.

### 3. `hdiutil verify` is NOT a content check

It only checks that the UDIF container decompresses to what was stored, not that
what was stored matches the source. So `make-dmg.sh` mounts the finished image
and md5s `quake2`, `ref_gl.so` and `game.so` **inside it** against the staged
source, retries up to 3x, and fails loud; it also md5-checks the scp-back.
`make-dmg.sh` re-checks slices with `lipo -archs` before packaging. **Never
weaken or skip this.**

The failure it exists for, 2026-05-31: the v2.2.3 DMG crashed instantly on the
G4-mini with `EXC_BAD_INSTRUCTION` / `Code[0]=0x2` (`EXC_PPC_PRIVINST`) at
`Con_Print+8`, inside `Qcommon_Init → Swap_Init → Com_Printf → Con_Print`.
Disassembling the shipped `ppc7400` slice showed one 32-bit word at that address
had become `0xe7e1fffc`, an undecodable opcode (PPC primary opcode 57, `lfdp`,
64-bit-only) that traps as privileged on a G4. The intended instruction was
`stw r31,0xfffc(r1)` = `0x93e1fffc`, a register save in the PIC prologue.
**Exactly one byte flipped: `0x93` → `0xe7`.** The local `build/q2-fat/quake2`
was clean. TCP, SSH and rsync all checksum the wire, so it was not a transfer
loss; it was almost certainly a RAM or disk glitch on the 1999 non-ECC Panther
G3 the image was being built on. `hdiutil verify` passed. The fix was this
verification plus moving the DMG host to Tiger (ADR 0005).

### 4. Verify at the last hop, not an earlier one

`deploy-dmg.sh` md5-verifies every installed binary (`ref_gl.so`, the in-bundle
`quake2`, `game.so`, `q2ded`) against the mounted image, retries the copy up to
4x, and fails loud with exit 7. `deploy.sh` md5s the deployed binary against
source.

The failure it exists for, 2026-05-31: the G3's installed `ref_gl.so` md5'd
wrong and the in-bundle `quake2` went missing, and re-deploys printed
"DMG on Desktop verified intact" then silently stopped.

**The wrong theory, recorded so it is not repeated: it was not flaky retro
hardware.** The G3 has a near-new SSD. Mounting the on-Desktop DMG on the G3 and
hashing its internal `ref_gl.so` gave the correct `060cc6dc…` three times
deterministically, and a copy-to-disk hashed clean too.

The real cause was a **stale mount**: ad-hoc diagnostic `hdiutil attach`
commands had left the image attached on the G3, so `deploy-dmg.sh`'s own mount
at `$HOME/q2install-mnt` came up empty, `ditto "$MNT/Quake2.app"` copied
nothing, and under `set -e` the remote install aborted immediately after
`rm -rf "$DEST/Quake2.app"`. Operationally: **detach stale mounts before
deploying, and never leave a diagnostic mount of the release image on a
target.** The deploy detaches its own mountpoint but not a foreign attach of the
same image.

### 5. Bump the version for every build that leaves this machine

`deploy.sh` and `make-dmg.sh` stamp `CFBundleShortVersionString` and
`CFBundleVersion` from `git describe`, so what got deployed is identifiable from
Finder's Get Info and from a crash report, not just the console. The static
plist's `5.11` is upstream's engine version and never changes.

### 6. Close the loop on a release

Fix → `make-dmg` (verified) → `deploy-dmg` → `smoke-dmg` on G3/G4/G5 → a human
starts a new game. Then publish, **download the published GitHub asset back and
md5-compare it to the verified source DMG.** Before tagging, fact-check the
README (per-CPU OS floors, framerate table), the in-DMG `README.txt` and the SVG
diagrams, those name SDKs and `-mmacosx-version-min` values and go stale
silently. State plainly which configurations are built but untested (ADR 0001).

## Implementation gotchas in the verify path

- **Panther's BSD `grep` has no `-o`.** Parse mount points with `sed`, or pass an
  explicit `-mountpoint`.
- **`ssh host bash -s "$LIST"` word-splits the arguments.** Hardcode the file
  list in the remote heredoc rather than passing a space-separated argument.
- Use `md5 file | awk '{print $NF}'` on the Macs; portable Panther through Lion.
- On the G3, detach carefully: loop-retry the detach then `rmdir` the empty
  mountpoint. **Never `rm -rf` a path that might still be a mounted read-only
  volume.**

## Consequences

- A build takes longer because nothing is reused across runs.
- A deploy that half-fails is now a hard error instead of a "done" that lies.
- Corruption on any host can be caught before it ships, but only for the files
  the verifier lists; adding a shipped binary means adding it to that list.
