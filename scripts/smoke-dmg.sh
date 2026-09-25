#!/bin/sh
# smoke-dmg.sh - path-stable shim, see scripts/pick-bench-host.sh's header
# for why this is a shim. Needs DMG_PORT_CONF set explicitly: the pinned
# smoke-dmg.sh looks for dmg-port.conf next to ITSELF once it runs from the
# pin cache, not next to this shim (build-host#105 pilot finding, alephone#43).
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
exec env DMG_PORT_CONF="$SELF_DIR/dmg-port.conf" "$SELF_DIR/shared.sh" smoke-dmg.sh "$@"
