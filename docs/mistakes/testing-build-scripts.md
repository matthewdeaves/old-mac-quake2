# Mistakes: testing build scripts

Traps hit while testing or committing script changes, all on 2026-08-22. Themes: stubbing the network does not make a build script safe; shell quoting in commit messages executes; sibling repos write into this working tree; a check that cannot read its input still prints a pass.

## Stubbing the network does not make a build script safe to run
`scripts/build.sh:247` is `rm -rf "$REPO_ROOT/build/q2-$TARGET"`, running long before anything touches a mini. A test with `rsync` and `ssh` stubbed on `PATH` reached it and deleted a real `ppc7400` slice; the stubbed fetch replaced nothing, leaving a `SOURCE-STAMP` with no binary. `build/q2-fat` was already fused so nothing shipped wrong, but the intermediate had to be rebuilt.
Run a build script against a COPIED tree with its own `REPO_ROOT`, never the live one (`build.sh` only needs `scripts/` and a writable `build/`).

## Backticks in `git commit -m "..."` RUN as commands
A commit message quoted a filing recipe inside backticks inside a double-quoted `-m`; the shell substituted it, so `gh issue create --project Retro` was EXECUTED. Nothing was created only because `gh` refuses without `--title`/`--body` non-interactively. The commit pushed with the text deleted ("It taught ,").
Commit messages here routinely quote shell: write them with a quoted heredoc (`git commit -F - <<'MSG'`). Never `-m` with backticks.

## `git add -A scripts/` swept another session's files into an unrelated commit
old-mac-build-host synced both host pickers into this tree with `sync-build-lock.sh --write` mid shellcheck triage; `git add -A scripts .github` took all of it, so `d25f2b81` carries 122 lines of picker changes under a shellcheck-only message, pushed before anyone looked. Code was good; the record was wrong and pushed history cannot be rewritten.
Nothing arbitrates working trees, only machines. Stage by name, or read `git status` immediately before `git add`; never `-A` on a directory a sync targets.

## A check that cannot read its input still prints a pass
Three in one session: `grep -rlE ... scripts | wc -l` gave `0` one-argument call sites while the dir was unreadable; `for spec in "a b c"` under zsh did not word-split, so six scripts ran under one garbage name and every case read "skipped"; `git show ... 2>&1 | shasum` hashed error text into a plausible `db132943...` when the real answer was `e3b0c442...` (sha256 of empty).
Redirect stderr separately, assert the input is readable and non-empty, and prove a negative check still FIRES on known-bad input before believing a clean run.
