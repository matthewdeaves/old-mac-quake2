# Quake II old-Mac port

Quake II on yquake2 5.11 as ONE fat PowerPC + Intel app, from a single `Quake2.app`, plus a Linux dedicated server from the same tree.

Sister project `~/quakespasm/` owns the shared infrastructure (SSH config, toolchain, vendored prerequisites, the fat SDL framework, host tooling). **Reuse it, do not re-invent it.**

All builds and CI are centralized on `old-mac-build-host`. There are no local Jenkinsfiles or CI build scripts in this repository.

## Documentation Router

To keep context lightweight, detailed instructions and reference materials are split into specific rule files in `.claude/rules/`. **Only read these files when your task specifically requires them.**

- **[.claude/rules/commands.md](.claude/rules/commands.md)**: Read when you need to compile the game, deploy builds, run benchmarks, or generate a DMG. It explains the core scripts and Jenkins jobs.
- **[.claude/rules/facts.md](.claude/rules/facts.md)**: Read when modifying game code, config layering, or rendering. It contains critical constraints (e.g. CPU slices, yquake2 5.11 pin, G5 fullscreen hazard, rendering bugs).
- **[.claude/rules/legacy-mac-hardware.md](.claude/rules/legacy-mac-hardware.md)**: Read when you need to understand the hardware fleet, OS targets, CPU architectures, or IP allocations for testing and deployment.
- **[.claude/rules/ticketing-workflow.md](.claude/rules/ticketing-workflow.md)**: Read when raising issues, assigning work across repos, managing hardware locks, or working with the project board.
- **[.claude/rules/read-on-demand.md](.claude/rules/read-on-demand.md)**: Read for pointers to other extensive documentation in `docs/` or `server/`.

## Architecture Decision Records (ADRs)

Project reasoning, rejected alternatives, and historical decisions live in `docs/adr/`. Settled negatives and "do not do this" examples live in `MISTAKES.md`.
