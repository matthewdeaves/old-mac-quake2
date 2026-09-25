#!/bin/sh
# deploy-dmg.sh - path-stable shim, see scripts/pick-bench-host.sh's header
# for why this is a shim.
#
# Two build-host#105 pilot findings (alephone#43) both apply here:
# - DMG_PORT_CONF must be set explicitly, same reason as smoke-dmg.sh's shim.
# - deploy-dmg.sh resolves a bare version arg, or the newest dist/*.dmg when
#   given none, relative to ITS OWN location -- the pin cache once wrapped,
#   not this repo. old-mac-build-host's generated jobs call this with no
#   version arg at all ("$REPO/scripts/deploy-dmg.sh" "$h"), relying on the
#   newest-in-dist/ default, so this shim resolves that itself, from this
#   repo's real dist/, and always passes an explicit full path through.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
DMG_PREFIX=; . "$SELF_DIR/dmg-port.conf"
# --update is a synonym the canonical script strips itself (host/version stay
# $1/$2 either way); strip it here too so this shim's own $1/$2 reading of
# host/version agrees with what it forwards on.
[ "${1:-}" = --update ] && shift
if [ -n "${2:-}" ]; then
	case "$2" in
		/*) DMG="$2" ;;
		*)  DMG="$REPO_ROOT/dist/${DMG_PREFIX}$2.dmg" ;;
	esac
else
	DMG="$(ls -t "$REPO_ROOT"/dist/"${DMG_PREFIX}"*.dmg 2>/dev/null | head -1)"
fi
[ -n "$DMG" ] && [ -f "$DMG" ] || { echo "deploy-dmg.sh: no DMG found (${2:-newest dist/*.dmg})" >&2; exit 2; }
exec env DMG_PORT_CONF="$SELF_DIR/dmg-port.conf" "$SELF_DIR/shared.sh" deploy-dmg.sh "$1" "$DMG"
