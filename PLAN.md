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
   Windows (x86_64, **arm64 promoted from optional to first-class** given Snapdragon X2 Elite
   is now competitive). Run under WSL2 on Windows where native isn't practical.
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

### Timing primitive

- **`hyperfine`** is the default wall-clock timer for any workload that runs in < 60 s.
  Gives us warmup control, outlier detection, shell overhead subtraction, and JSON export
  for free. Long workloads (compiles) use a thin wrapper (`scripts/common/time_run.sh` /
  `.ps1`) that emits the same JSON shape.
- **Long runs**: minimum 3 iterations, report min / median / max / stddev.
- **Short runs** (< 10 s): hyperfine with `--warmup 3 --min-runs 10`.

### Statistical bar for "A beats B"

- Only claim a difference when **median delta > 5%** AND **non-overlapping IQR** across the
  iteration set. Otherwise flag as "within noise".
- Always report **stddev** alongside median. High stddev = suspect, flagged in report.
- Outliers auto-detected (hyperfine's built-in); > 2 outliers out of 10 invalidates the run.

### Required discipline per run

- **3 back-to-back iterations** minimum per long workload; 10 for short ones.
- **Cold + warm** variants for compile and I/O workloads.
  - Cold: drop caches (`purge` / `echo 3 > /proc/sys/vm/drop_caches` / `RAMMap -Ew`), blow
    away build dirs and ccache/sccache.
  - Warm: second run right after cold.
- **Plugged AND battery** on laptops (two separate result sets).
- **Thermals**: record CPU package temp at start/mid/end of each run (`powermetrics`,
  `turbostat`, `HWiNFO` csv logging). Flag throttling with a hard boolean in output.
- **Background noise kill-list** per OS documented in `docs/preflight.md`.
- **Energy**: wall-clock joules via `powermetrics` (mac), `turbostat --show PkgWatt` (linux),
  RAPL via `LibreHardwareMonitor` (windows x86), `EnergyLib` / PDH counters (windows arm).
- **Native only** for headline numbers. Separate "emulation" category.
- **SMT/HT on by default** (real-world setting). Run a one-off "SMT off" comparison on desktop
  x86 to quantify — not a mandatory tier.
- **Power mode matrix** (Mac): Default / Low Power / High Power (MBP 16" only). Record as tag.
- **FS mode matrix** (Mac): APFS case-sensitive vs insensitive — we pin insensitive (default);
  note when a workload is sensitive to it (xcode/swift).

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

Purpose: the workload developers actually wait on. Hammers cache, memory bandwidth, FS, scheduler, linker.

| Project | Toolchain | Variants |
|---|---|---|
| LLVM 22.1.x (release tag pinned) | clang + ninja, no ccache, default linker | cold `-j1`, cold `-jN`, warm `-jN`, incremental (touch pinned file, see below) |
| Linux kernel (defconfig, tag pinned 6.18 LTS) | gcc | cold `-jN`, incremental — Linux & WSL only |
| ripgrep (tag pinned) | `cargo build --release`; on Linux also a `mold` linker run for comparison | cold, incremental |
| TypeScript 6.x compiler self-build (`tsc`) | `npm ci && npm run build` | cold, incremental |
| **TypeScript 7 `tsgo` type-check** | `tsgo --noEmit` on TypeScript repo | cold only — the new Go-native compiler (~10x faster, tests scheduler/goroutines) |
| Kubernetes (tag pinned) | `go build ./...`, `GOCACHE=off` cold, default warm | cold, warm |
| DuckDB (tag pinned) | clang/cmake/ninja | cold — heavy C++ templates |
| Swift Package Manager medium project | `swift build -c release` | cold, incremental — macOS + Linux (not Windows) |

Key derived metrics:
- **MT scaling ratio** = time(-j1) / time(-jN) — reveals memory-bandwidth ceiling
- **Incremental ratio** = time(incremental) / time(warm full) — build-graph overhead
- **Link fraction** = time(link phase) / time(total) — linker + storage latency

Incremental "touch one file" is pinned per project for reproducibility (defined in `configs/incremental_files.yaml`, e.g. LLVM → `llvm/lib/Analysis/ValueTracking.cpp`, TypeScript → `src/compiler/checker.ts`, kernel → `mm/page_alloc.c`, etc.). Just `touch` to bump mtime; no content change.

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
- Same under **Prism** (Windows 11 arm64 x86_64 emulation) — now a real target with Snapdragon X2
- Docker x86_64 image on arm64 host (QEMU user-mode / `docker buildx --platform`)

Purpose: quantify cost of living in the "other arch" world.

### Tier 6 — Modern dev-velocity workloads

Purpose: represent how devs actually spend wall-clock time in 2026 — not compiling, but running
package managers, bundlers, linters, test-watchers. These are all Rust-or-Go rewrites of older
tools and scale very differently from their predecessors.

| Workload | Tool | Notes |
|---|---|---|
| `uv pip install` a medium stack (pandas, fastapi, ruff, mypy, jupyter) | `uv` | cold cache (`--refresh`) + warm |
| `pnpm install` on next.js repo | `pnpm` | cold + warm store |
| `bun install` same deps | `bun` | parity check |
| `ruff check` full pandas repo | `ruff` | modern Python linter, single-thread Rust |
| `cargo clippy` on ripgrep | rust toolchain | everyday lint pass |
| Vite dev server cold start | `vite` | time to first HMR-ready |
| esbuild bundle a medium repo | `esbuild` | bundler throughput |

### Tier 7 — Local AI inference (new, mandatory in 2026)

Purpose: a daily dev workload now (local code assist, agents, embeddings for RAG). Heavily
unified-memory-bound — the clearest differentiator between Apple Silicon and x86+dGPU setups.

| Workload | Engine | Notes |
|---|---|---|
| Qwen2.5-Coder 7B Q4_K_M prompt eval + generate | `llama.cpp` (GGUF), CPU-only | cross-platform baseline |
| Same model, accelerated | `llama.cpp` with Metal (Mac), CUDA (NV), Vulkan (AMD/Intel), QNN (Snapdragon) | per-platform best |
| Same model | `MLX` (Mac-only) | fair comparison vs llama.cpp on same hw |
| Whisper-large-v3 on a pinned 10-min audio | `whisper.cpp` | realistic dev task |
| Embedding throughput with `nomic-embed-text-v1.5` | `llama.cpp` | tokens/s for RAG |

Report: **effective end-to-end throughput** (include prefill, not just decode), prefill tok/s,
generate tok/s, peak RAM, W during inference, tokens-per-joule. Raw decode-only numbers are
misleading (public MLX benchmarks often inflate by ignoring prefill).

## Container / VM runtime matrix (macOS)

Docker performance on Mac varies wildly by runtime. Headline numbers use **OrbStack** (fastest,
modern VZ-backed). Side experiment runs also record Docker Desktop, colima (VZ), and Podman
Machine. Linux uses native dockerd; Windows uses Docker Desktop (WSL2 backend) + Podman.

## Calibration & self-test

- `scripts/common/self_test.sh` runs the suite on a known synthetic workload (e.g., `sysbench` + a
  10-second sleep + a 100 MB file hash) 5 times. If stddev > 3% it fails and tells the user to
  re-run `docs/preflight.md`. Required before any real run.
- A `--dry-run` flag that verifies every tool is installed at the pinned version without running.

## Reference baseline

`docs/reference_machines.md` will track numbers from a fixed set of machines we can replicate:
- MacBook Pro 14" M4 Pro 12c/16c (24 GB RAM)
- MacBook Pro 16" M4 Max 16c/40c (64 GB RAM)
- MacBook Air M3 8c (16 GB RAM) — thermal-limited baseline
- Desktop: Ryzen 9 7950X3D + DDR5-6000 + Samsung 990 Pro 2 TB + Ubuntu 24.04
- Desktop: Intel 14900K + DDR5-6400 + 990 Pro + Win11 and Ubuntu 24.04
- Snapdragon X2 Elite laptop (Windows 11 arm64)
- Optional: Lenovo Thinkpad AMD 8840U (mobile x86 reference)

Publishing at least two data points per machine (plugged + battery where applicable).

## Deliverables

- `scripts/run.sh` (macOS + Linux) and `scripts/run.ps1` (Windows) — top-level orchestrators.
- Shared YAML config (`configs/default.yaml`) defining workloads, versions, iterations.
- Per-workload scripts under `workloads/<name>/` with `run.sh` + `run.ps1` (or single portable script).
- Per-OS bootstrap installing toolchains at pinned versions (`scripts/{linux,macos,windows}/bootstrap.*`).
- JSON results schema in `docs/schema.json`.
- Aggregator `scripts/common/aggregate.py` → merges runs into a single CSV + markdown report.
- Optional HTML dashboard (Vega-Lite spec) for visual comparison.
- `LICENSE` = **Apache-2.0** (permissive, compatible with all deps).

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

- **M1** — Repo scaffolding + this plan + schema + default config. *(done)*
- **M2** — Host probe scripts (detect + dump hardware/OS metadata) for all 3 OSes + self-test.
- **M3** — Tier 1 synthetic suite end-to-end on macOS + Linux (hyperfine-wrapped).
- **M4** — Tier 2 compile suite (LLVM + ripgrep + TypeScript 6 + tsgo 7) on macOS + Linux.
- **M5** — Windows parity (PowerShell wrappers, winget bootstrap, Windows arm64 first-class).
- **M6** — Tier 3 runtime + Tier 4 dev-day.
- **M7** — Tier 6 dev-velocity (uv/pnpm/bun/ruff/vite).
- **M8** — Tier 7 local AI inference (llama.cpp + MLX + whisper).
- **M9** — Aggregator, markdown comparison report, reference-machine table.
- **M10** — HTML dashboard, docs, first public results post.

## Open questions

- **Phoronix Test Suite** as a dep vs reimplement the bits we need? → **reimplement**
  (keeps the suite small/self-contained, avoids PTS's "run everything" mindset).
- How to fairly handle Apple's undocumented SLC / memory-compression wins in microbenchmarks?
  → report as measured with a footnote. Unified memory + SLC *is* faster in practice — that's
  the point of measuring it.
- Docker on Mac runtime choice for headline? → **OrbStack** (fastest VZ-backed). Docker Desktop,
  colima, Podman as side experiments.
- Go toolchain caching: `GOCACHE=off` cold is honest but unrealistic → run both, labelled.
- Disk encryption (FileVault / LUKS / BitLocker) overhead: on by default (real-world), but
  include one "encryption off" run on the reference x86 desktop as a side note.
- **TypeScript 7 `tsgo` vs 6 `tsc`**: both included; report the ratio — genuinely interesting
  signal on how scheduler/goroutine perf has reshaped the compiler landscape.
- **Windows Defender**: run twice (on/off) for compile workloads only — the delta is large
  (~15–40%) and matters for anyone reading the report.
- **Ambient AI assistants** (Copilot, Cursor agents, etc.) are active on real dev machines and
  can cost 5–15% CPU. For benchmarking: off, because they introduce non-deterministic load.
- **Swap**: at least one test deliberately exceeds RAM to expose swap behaviour. Macs with
  high-bandwidth SSD handle this very differently from systems with DDR + SATA SSD. Proposed:
  a 48 GB in-memory sort on a 32 GB-RAM machine.
- **Filesystem for compile scratch on Linux**: default to whatever the distro ships (ext4/xfs).
  btrfs-on-zstd is noticeably different — record as tag, don't branch.
