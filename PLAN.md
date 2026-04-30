# devbench — Developer Machine Benchmark Suite

A cross-platform (macOS, Linux, Windows) benchmark suite focused on **real developer workloads**
augmented with a small set of synthetic tests for sanity checking. Designed to give an honest
answer to: "Is an Apple Silicon laptop actually faster than my x86 desktop/laptop for my daily
dev work?"

## Goals

1. **Honest** — measure what devs actually do (compile, test, search, build containers), not
   abstract FLOPS.
2. **Reproducible** — pinned tool versions, pinned source revisions, scripted setup, JSON output.
3. **Cross-platform** — same workloads run on macOS (arm64, x86_64), Linux (arm64, x86_64),
   Windows (x86_64; arm64 optional). Run under WSL2 on Windows where native isn't practical.
4. **Fair to both camps** — native binaries on each arch, separate "emulation tax" category for
   Rosetta/Prism runs.
5. **Report ratios, not just absolute numbers** — cold vs warm, `-j1` vs `-jN`, plugged vs
   battery, perf vs perf/W.

## Non-goals

- Gaming benchmarks.
- GPU compute (separate suite if we want it later).
- Anything requiring paid licenses (SPEC, Geekbench Pro).
- Micro-optimized "hero number" benchmarks no one runs in practice.

## Methodology

### Required discipline per run

- **3 back-to-back iterations** per workload. Report min / median / max.
- **Cold + warm** variants for compile and I/O workloads.
  - Cold: drop caches (`purge` / `echo 3 > /proc/sys/vm/drop_caches` / `RAMMap -Ew`), blow
    away build dirs and ccache.
  - Warm: second run right after cold.
- **Plugged AND battery** on laptops (two separate result sets).
- **Thermals**: record CPU package temp at start/mid/end of each run (`powermetrics`,
  `turbostat`, `HWiNFO` csv logging). Flag throttling.
- **Background noise kill-list** per OS documented in `docs/preflight.md`.
- **Energy**: wall-clock joules via `powermetrics` (mac), `turbostat --show PkgWatt` (linux),
  `PresentMon` or RAPL via `LibreHardwareMonitor` (windows).
- **Native only** for headline numbers. Separate "emulation" category.

### What we always record

| Field | Source |
|---|---|
| CPU model, core topology (P/E), base/boost freq | `sysctl` / `lscpu` / `wmic cpu` |
| RAM size, speed, channels | `system_profiler` / `dmidecode` / `wmic memorychip` |
| Storage model, filesystem | `diskutil` / `lsblk` + `df -T` / `Get-PhysicalDisk` |
| OS + kernel version | `uname -a` / `ver` |
| Compiler versions | pinned, recorded |
| Power source | platform API |
| Ambient "idle" CPU % for 30s before run | sampled |

## Test Matrix

### Tier 1 — Synthetic baseline (fast, ~10 min total)

Purpose: sanity check, cross-reference with public numbers.

| Test | What it measures | Tool |
|---|---|---|
| CPU ST | single-thread integer | `sysbench cpu --threads=1` |
| CPU MT | all-core integer scaling | `sysbench cpu --threads=$(nproc)` |
| Memory bandwidth | stream copy/triad | STREAM (custom build) |
| Memory latency | random load | `mlc` (linux x86) / `stress-ng --memrate` fallback |
| Compression MIPS | cross-arch reference | `7z b -mmt=on` and `-mmt1` |
| Storage 4K QD1 | SSD latency (random read) | `fio` |
| Storage seq | SSD throughput | `fio` |
| Storage mixed | realistic dev pattern | `fio` (iomix profile) |

### Tier 2 — Compilation (the main event, ~1–2 h total)

Purpose: the workload developers actually wait on. Hammers cache, memory bandwidth, FS, scheduler.

| Project | Toolchain | Variants |
|---|---|---|
| LLVM 19.1.x (release tag pinned) | clang + ninja, no ccache | cold `-j1`, cold `-jN`, warm `-jN`, incremental (touch 1 file) |
| Linux kernel (defconfig, tag pinned) | gcc | cold `-jN`, incremental — Linux & WSL only |
| ripgrep (tag pinned) | `cargo build --release` | cold, incremental |
| TypeScript compiler self-build | `npm ci && npm run build` | cold, incremental |
| Kubernetes (tag pinned) | `go build ./...` | cold, warm |
| DuckDB (tag pinned) | clang/cmake/ninja | cold — heavy C++ templates |
| A Swift Package Manager medium project | `swift build -c release` | cold, incremental — macOS + Linux (not Windows) |

Key derived metrics:
- **MT scaling ratio** = time(-j1) / time(-jN)
- **Incremental ratio** = time(incremental) / time(warm full)

### Tier 3 — Test execution / runtime

| Workload | Tool |
|---|---|
| pytest on pandas (pinned tag) | `pytest -n auto` + `-n1` |
| node.js test suite or next.js `npm test` | `npm test` |
| JVM: Renaissance suite (representative subset) | `java -jar renaissance.jar` |
| `docker build` of a multi-stage Rust image | docker |

### Tier 4 — "Dev day" mixed workload

Scripted sequence against a large mono-repo (torvalds/linux at a pinned tag, ~5 GB, shallow clone disallowed):

1. `git status` (cold and warm)
2. `git log --oneline | wc -l`
3. `rg "TODO|FIXME" --stats` across the tree
4. `fd -e c` full traversal
5. `git grep -n "static inline"`
6. Git blame on a 5k-line file (`kernel/sched/core.c`)
7. Git checkout between two tags 6 months apart

### Tier 5 — Emulation tax (optional, separate category)

- Same compile workloads under Rosetta 2 (macOS arm64 running x86_64 toolchains)
- Same under Prism / x86_64 emulation on Windows arm64
- Docker x86_64 image on arm64 host (QEMU user-mode)

Purpose: quantify cost of living in the "other arch" world.

## Deliverables

- `scripts/run.sh` (macOS + Linux) and `scripts/run.ps1` (Windows) — top-level orchestrators.
- Shared YAML config (`configs/default.yaml`) defining workloads, versions, iterations.
- Per-workload scripts under `workloads/<name>/` with `run.sh` + `run.ps1` (or single portable script).
- Per-OS bootstrap installing toolchains at pinned versions (`scripts/{linux,macos,windows}/bootstrap.*`).
- JSON results schema in `docs/schema.json`.
- Aggregator `scripts/common/aggregate.py` that merges runs into a single comparison CSV + markdown report.
- Optional HTML dashboard (Vega-Lite spec) for visual comparison.

## Output format

Each run emits `results/<hostname>-<YYYYMMDD-HHMMSS>/run.json`:

```jsonc
{
  "host": {"hostname":"...","os":"...","cpu":{"model":"...","cores_p":8,"cores_e":4}, "ram_gb":64, "storage":"..."},
  "runtime": {"started":"...","ended":"...","power_source":"ac","ambient_cpu_pct":1.2},
  "results": [
    {
      "id": "compile.llvm.cold.jN",
      "tier": 2,
      "iterations": [
        {"wallclock_s":412.3,"user_s":..., "sys_s":..., "peak_rss_mb":...,
         "avg_package_w":..., "energy_j":..., "cpu_temp_c":{"start":42,"mid":88,"end":91}}
      ]
    }
  ]
}
```

## Milestones

- **M1** — Repo scaffolding + this plan + schema. *(this commit)*
- **M2** — Host probe scripts (detect + dump hardware/OS metadata) for all 3 OSes.
- **M3** — Tier 1 synthetic suite end-to-end on macOS + Linux.
- **M4** — Tier 2 compile suite (LLVM + ripgrep + TypeScript) on macOS + Linux.
- **M5** — Windows parity (PowerShell wrappers, winget bootstrap).
- **M6** — Tier 3–4 workloads.
- **M7** — Aggregator + comparison report.
- **M8** — Dashboard, docs, first public results table.

## Open questions

- Do we want Phoronix Test Suite as a dependency (saves work, adds a big Perl dep) or reimplement the bits we need?
  Current lean: **reimplement** — keeps the suite small, self-contained, and avoids PTS's "run everything" mindset.
- How to fairly handle Apple's undocumented SLC / memory-compression wins in microbenchmarks?
  Current plan: report the numbers as measured with a footnote. The whole point is that
  unified memory + SLC *is* faster in practice.
- Docker on Mac: Docker Desktop vs colima vs OrbStack vs native lima? Pick one (**OrbStack**)
  for headline numbers, run all three as a side experiment.
- Go toolchain caching: `GOCACHE` off is the honest setting for "cold" but unrealistic. Run both.
