#!/bin/sh
# SOURCED, NOT RUN. This repo's exclude list for source-stamp.sh.
#
# It lives here rather than in source-stamp.sh because that file is canonical in
# old-mac-build-host, byte-identical across five repos, and a drift check
# enforces that. The names below are this port's layout, not the fleet's, so the
# shared file takes the list as a PARAMETER and each port supplies its own. See
# THE SHARED SURFACE in scripts/source-stamp.sh. This repo wrote the original
# one-argument version; the list is the part of it that stayed here.
#
# Pass the SAME list to source_stamp_compute and source_stamp_rsync_excludes, so
# what is hashed and what is copied to the build mini cannot disagree. A file
# outside this set cannot affect a build; a file inside it must change the hash.
#
# yquake2/release/ is the engine Makefile's OUTPUT directory, gitignored by both
# .gitignore:4 and yquake2/.gitignore:2 and tracked by nothing. It was in the
# hashed set until 2026-08-22. build.sh builds on the mini and fetches from the
# REMOTE release/, so it never writes the local one; build-arm64.sh compiles in
# place and does, and runs `make clean` first. So the hash of an unchanged source
# tree moved depending on whether an arm64 build had run. Build output must never
# be part of "what the source is".
#
# .claude/ is Claude Code session state, not source: commands and skills under
# it ARE git-tracked, but scheduled_tasks.lock and settings.local.json are
# gitignored (.gitignore) and live inside $REPO_ROOT, so source_stamp_compute
# walks the real filesystem and hashes them regardless of .gitignore — that
# list is separate from this one and this check does not consult it. Same
# failure mode as yquake2/release/ above (something inside the tree moving the
# hash without the engine source changing), just triggered by session
# bookkeeping: a ScheduleWakeup between an arm64 build and a fat build moves
# scheduled_tasks.lock's mtime and refuses a same-commit slice as stale. Found
# and fixed first in the sibling old-mac-quakespasm repo, same gap here.
#
# Newline-separated, NOT space-separated. Reading it with `for e in $VAR` would
# depend on word-splitting, which sh and bash do and zsh does NOT: sourced from a
# zsh shell the whole list collapses to one word, nothing is pruned, and the hash
# silently covers build/ and fires on every bench run.
# Read by the four call sites listed above, in files shellcheck parses
# separately, so it cannot see the use. Not an export: the shared file takes
# the list as an argument. Issue #22.
# shellcheck disable=SC2034
SOURCE_STAMP_EXCLUDES='.git
*.o
*.d
build/
benchmarks/
prereqs/
yquake2/release/
reference/
.claude/'
