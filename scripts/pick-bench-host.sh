#!/bin/sh
# pick-bench-host.sh - path-stable shim onto build-host#105's pinned scripts
# (docs/adr/0007 in old-mac-build-host, this repo's shared-scripts.pin).
#
# Kept at THIS path, not deleted, because old-mac-build-host's generated
# Jenkins jobs (jenkins/generated/job-smoke-quake2-*.xml,
# job-release-fanout-quake2.xml) invoke it as "$REPO/scripts/pick-bench-host.sh"
# by fixed path (build-host#119, halflife#49's fix for the same gap).
# bench-evidence.sh/bench-compare.sh/gui-precondition.sh/clear-launch-quarantine.sh/
# pick-build-host.sh have no such caller here and stay deleted.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SELF_DIR/shared.sh" pick-bench-host.sh "$@"
