# shellcheck shell=bash
# Quake II's hooks for the shared deploy-dmg.sh / smoke-dmg.sh
# (old-mac-build-host#96). Ours, never synced. Sourced by both scripts.

# Refuse an image that is short a slice, lacks the arm64 SDL2 companion, or
# fails its signature, before anything reaches a Mac.
preflight_local() {
	local mnt="$1" archs
	. "$REPO_ROOT/scripts/macho-archs.sh"
	archs=$(macho_archs "$mnt/Quake2.app/Contents/MacOS/quake2")
	[ "$archs" = "ppc750 ppc7400 ppc970 x86_64 i386 arm64" ] || {
		echo "quake2 preflight: slice mismatch: $archs" >&2; return 1; }
	[ -f "$mnt/Quake2.app/Contents/MacOS/libSDL2-2.0.0.dylib" ] || {
		echo "quake2 preflight: arm64 SDL2 companion missing" >&2; return 1; }
	codesign --verify --deep --strict "$mnt/Quake2.app" || {
		echo "quake2 preflight: signature invalid" >&2; return 1; }
}

# Runs in the stage on the target. The workstation is the one Mac where a
# person hand-edits the bundled controls cfg (sound on); keep lines there
# that the new build doesn't ship. Never on fleet hosts: it would bring back
# a line a release deliberately dropped. (#85)
# shellcheck disable=SC2034  # read by the sourcing deploy-dmg.sh
REMOTE_POST_STAGE='
if [ "$HOST" = workstation ]; then
	C=Quake2.app/Contents/Resources/autoexec-controls.cfg
	if [ -f "$DEST/$C" ] && [ -f "$C" ]; then
		grep -vxF -f "$C" "$DEST/$C" > .q2-local-lines 2>/dev/null || true
		if [ -s .q2-local-lines ]; then
			echo "kept local lines in $C:"; sed "s/^/    /" .q2-local-lines
			cat .q2-local-lines >> "$C"
		fi
		rm -f .q2-local-lines
	fi
fi'

# The port's last word on its own log. A host with no fullscreen mode never
# reaches the renderer: NOT TESTED (3), not a failed build (headless minis).
# A pass also needs the live read-back of the effective video cvars (4).
smoke_verdict() {
	local log="$1" rc="$2" cv missing=
	if grep -Eq 'SetVideoMode failed|No video mode large enough' "$log"; then
		echo "[smoke $HOST] NOT TESTED: this host offers no fullscreen video mode"
		return 3
	fi
	[ "$rc" = 0 ] || return "$rc"
	for cv in gl_bloom gl_msaa_samples gl_mode gl_customwidth gl_customheight \
		vid_fullscreen vid_desktopfullscreen gl_swapinterval; do
		grep -q "^\"$cv\" is \"" "$log" || missing="$missing $cv"
	done
	if [ -n "$missing" ]; then
		echo "[smoke $HOST] FAIL: live cvar read-back missing:$missing"
		return 4
	fi
	grep -E '^"(gl_bloom|gl_msaa_samples|gl_scene_resolve|gl_mode|gl_custom(width|height)|vid_(desktop)?fullscreen|gl_swapinterval)" is' "$log" | sed 's/^/    /'
	return 0
}
