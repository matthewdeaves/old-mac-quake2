#!/bin/bash
# watch_enable A/B on the workstation. Scratch copy under ~/oldmac, never /Applications.
set -u
REPO=/Users/matt/Documents/old-mac-quake2
S=/private/tmp/claude-502/-Users-matt-Documents-old-mac-quake2/1f618325-ac5c-42ce-bd2d-c40253c9bfb4/scratchpad
T=$HOME/oldmac/quake2/watch-test
OUT=$S/watch-results
UD=$HOME/.yq2/baseq2
mkdir -p "$OUT"

# Preserve the user's config and log.
cp -p "$UD/config.cfg" "$OUT/config.cfg.user-backup"
[ -f "$UD/qconsole.log" ] && cp -p "$UD/qconsole.log" "$OUT/qconsole.log.user-backup"
restore() {
  cp -p "$OUT/config.cfg.user-backup" "$UD/config.cfg"
  if [ -f "$OUT/qconsole.log.user-backup" ]; then cp -p "$OUT/qconsole.log.user-backup" "$UD/qconsole.log"; else rm -f "$UD/qconsole.log"; fi
}
trap restore EXIT

build_tree() { # $1 = new|old
  rm -rf "$T"; mkdir -p "$T/baseq2"
  cp -R /Applications/Quake2/Quake2.app "$T/"
  ln -s /Applications/Quake2/baseq2/pak0.pak "$T/baseq2/pak0.pak"
  ln -s /Applications/Quake2/baseq2/pak1.pak "$T/baseq2/pak1.pak"
  ln -s /Applications/Quake2/baseq2/players "$T/baseq2/players"
  if [ "$1" = new ]; then
    cp "$REPO/build/arm64/release/quake2" "$T/Quake2.app/Contents/MacOS/quake2"
    cp "$REPO/build/arm64/release/ref_gl.so" "$T/ref_gl.so"
    cp "$REPO/build/arm64/release/baseq2/game.so" "$T/baseq2/game.so"
  else
    cp /Applications/Quake2/ref_gl.so "$T/ref_gl.so"
    cp /Applications/Quake2/baseq2/game.so "$T/baseq2/game.so"
  fi
}

run_case() { # $1 name, $2 new|old, rest = extra args
  name=$1; kind=$2; shift 2
  build_tree "$kind"
  rm -f "$UD/qconsole.log"
  cp -p "$OUT/config.cfg.user-backup" "$UD/config.cfg"
  python3 - "$OUT/$name.udp" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 27999)); s.settimeout(0.5)
n = 0; kinds = {}; end = time.time() + 24
while time.time() < end:
    try:
        d, _ = s.recvfrom(4096)
    except socket.timeout:
        continue
    n += 1
    for line in d.decode("utf-8", "replace").splitlines():
        k = line.split('"t":"', 1)[1].split('"', 1)[0] if '"t":"' in line else "?"
        kinds[k] = kinds.get(k, 0) + 1
open(sys.argv[1], "w").write("packets=%d kinds=%s\n" % (n, kinds))
PY
  lpid=$!
  sleep 1
  "$T/Quake2.app/Contents/MacOS/quake2" -nolauncher +set logfile 2 +set s_initsound 0 \
    +set vid_fullscreen 0 +set vid_desktopfullscreen 0 +set gl_mode 3 "$@" +map base1 \
    > "$OUT/$name.stdout" 2>&1 &
  gpid=$!
  sleep 20
  kill -TERM "$gpid" 2>/dev/null; sleep 2; kill -KILL "$gpid" 2>/dev/null
  wait "$lpid" 2>/dev/null
  cp "$UD/qconsole.log" "$OUT/$name.qconsole.log" 2>/dev/null
  printf '%s: %s | watchlink lines: %s | watch_enable=%s | map=%s\n' "$name" \
    "$(cat "$OUT/$name.udp")" \
    "$(grep -c '^watchlink' "$OUT/$name.qconsole.log" 2>/dev/null)" \
    "$(grep -o 'watch_enable "[^"]*"' "$UD/config.cfg" | head -1)" \
    "$(grep -c -i 'base1\|Outer Base' "$OUT/$name.qconsole.log" 2>/dev/null)"
  grep '^watchlink' "$OUT/$name.qconsole.log" 2>/dev/null | sed 's/^/    /'
}

run_case A0-old-production old
run_case A-new-production new
run_case B-new-enable-literal new +set watch_enable 1 +set watch_host 127.0.0.1:27999
run_case C-new-enable-auto new +set watch_enable 1
rm -rf "$T"
