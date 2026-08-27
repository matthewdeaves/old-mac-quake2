## Machines

| Machine | CPU | GPU | OS | Slice |
|---|---|---|---|---|
| **yosemite** PowerMac1,1 | 449 MHz PPC 750 | ATI Rage 128 16 MB | 10.3.9 Panther | `ppc750` |
| **yosemite-tiger** same Mac, 2nd partition | 449 MHz PPC 750 | ATI Rage 128 16 MB | 10.4.11 Tiger | `ppc750` |
| **sawtooth** PowerMac3,1 | 500 MHz PPC 7400 | NVIDIA GeForce2 MX 32 MB | 10.4.11 Tiger | `ppc7400` |
| **quicksilver** PowerMac3,5 | 733 MHz PPC 7450 | ATI Radeon 9000 Pro 64 MB | 10.4.11 Tiger | `ppc7400` |
| **mini-g4** PowerMac10,1 | 1.25 GHz PPC 7447A | ATI Radeon 9200 32 MB | 10.4.11 Tiger | `ppc7400` |
| **imac-g5** PowerMac8,2 | 2.0 GHz PPC 970FX | ATI Radeon 9600 128 MB | 10.5.8 Leopard, native 1440x900 | `ppc970` |
| **mini-intel** Macmini2,1 | 2.33 GHz Core 2 Duo | Intel GMA 950 64 MB | 10.7.5 Lion | `x86_64` |
| **imac-2019** iMac19,1 | 3.7 GHz i5-9600K | AMD Radeon Pro 580X 8 GB | 15.7 Sequoia | `x86_64` |

Two build minis: `mini-intel` (10.188.1.190) and `mini-intel2`
(10.188.1.164), same Macmini2,1 / 10.7.5 / identical toolchain.

`yosemite` and `yosemite-tiger` are **one machine on one IP** with two OS
partitions; only one is booted at a time. Switch with
`ssh yosemite 'sudo bless --mount "/Volumes/<vol>" --setBoot'` then plain
`sudo /sbin/reboot </dev/null`, **not** `sudo -n`, which Tiger's and Panther's
sudo 1.6.x reject outright. `parallel-bench.sh` refuses to run both legs.
