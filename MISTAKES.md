# Mistakes log — things we tried that were bad

Append-only record of changes that landed in tree (or were attempted)
and turned out to be wrong, harmful, or otherwise misjudged. Each
entry exists so future rounds don't re-litigate the same idea on
incomplete information.

Format: date, what we tried, what went wrong, what the fix was, what
we learned. Newest at the top.

See `~/quakespasm/MISTAKES.md` for cross-applicable lessons from the
sister project — especially anything about benchmark concurrency
(don't run g3+g4 builds in parallel; don't run bench.sh legs
concurrently from one shell), and SDL framework dyld install_name
quirks.

---

*(no entries yet — Phase A has not started)*
