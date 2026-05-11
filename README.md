# yquake2 PPC port

Sister project to [`~/quakespasm/`](../quakespasm). Same hardware fleet
(6 retro Macs spanning 1999–2019), same build/deploy/bench cadence,
different engine.

**Engine base:** yquake2 5.11 (last release with native SDL 1.2 support).
**Goal:** most graphically advanced Quake II that runs playably on all 6 machines.

Roadmap in [`PPC_PLAN.md`](PPC_PLAN.md), durable facts in [`CLAUDE.md`](CLAUDE.md),
known dead-ends in [`MISTAKES.md`](MISTAKES.md).

## Hardware fleet

| Machine | CPU | GPU | OS |
|---|---|---|---|
| **yosemite** | 449 MHz PPC 750 | Rage 128 16 MB | 10.3.9 Panther |
| **sawtooth** | 500 MHz PPC 7400 | GeForce2 MX 32 MB | 10.4.11 Tiger |
| **quicksilver** | 733 MHz PPC 7450 | Radeon 9000 Pro 64 MB | 10.4.11 Tiger |
| **mini-g4** | 1.25 GHz PPC 7447A | Radeon 9200 32 MB | 10.4.11 Tiger |
| **mini-intel** | 2.33 GHz Core 2 Duo | Intel GMA 950 | 10.7.5 Lion |
| **imac-2019** | 3.7 GHz i5-9600K | AMD Radeon Pro 580X 8 GB | 15.7 Sequoia |

## Current status

**Pre-Phase-A** (project initialization, 2026-05-11). yquake2 5.11
checked out, reference repos cloned, scripts not yet adapted from
sister project.
