# devbench

A cross-platform (macOS / Linux / Windows) benchmark suite for **real developer workloads**:
compilation, test suites, container builds, code search, plus a synthetic baseline.

Built to answer the question "is this machine actually faster for the work I do?" without
trusting a single proprietary score.

See [PLAN.md](./PLAN.md) for design, methodology, and milestones.

## Status

**M4 — Tier 2 compile suite runnable (ripgrep, TypeScript tsc + tsgo, kubernetes, LLVM, DuckDB, Linux kernel).** Tier 3 runtime + Windows orchestrator next.

### Full pipeline (macOS / Linux / WSL)

```bash
./scripts/macos/bootstrap.sh --baseline --toolchains   # or scripts/linux/bootstrap.sh
./scripts/run.sh --tier 1 --iterations 3               # synthetic, ~10 min
./scripts/run.sh --tier 2 --iterations 2               # compile, ~1-3h (LLVM dominates)
./scripts/run.sh --tier 1,2 --iterations 2             # both
# -> results/<hostname>-<UTC timestamp>/run.json
```

> **Tier 2 note**: use `--iterations 2` (not 3) unless you have all day. LLVM cold_jN alone is ~15–30 min per iteration. For a first signal run just the fast ones with `--tier 2` after editing the spec list in `scripts/run.sh`, or run a single workload directly.

### Runnable building blocks

```bash
./scripts/common/self_test.sh                      # calibration, fails if CV > 3%
./scripts/macos/probe.sh                           # host JSON (CPU, RAM, disk, OS)
./scripts/common/runtime_init.sh --config configs/default.yaml
./scripts/common/time_run.sh --id demo -- <cmd>

# Individual Tier 1 workloads
./workloads/synthetic/sysbench_cpu/run.sh --threads 1
./workloads/synthetic/sysbench_cpu/run.sh --threads $(sysctl -n hw.logicalcpu)
./workloads/synthetic/sevenzip/run.sh
./workloads/synthetic/fio/run.sh --profile 4k_qd1 --scratch-dir /tmp/devbench

# Individual Tier 2 workloads (clone + build pinned tag)
./workloads/compile/ripgrep/run.sh --variant cold          # ~30-90s
./workloads/compile/ripgrep/run.sh --variant incremental   # ~1-10s
./workloads/compile/typescript/run.sh --variant tsc_cold
./workloads/compile/typescript/run.sh --variant tsgo_typecheck
./workloads/compile/kubernetes/run.sh --variant cold
./workloads/compile/llvm/run.sh --variant cold_jN          # ~15-30min!
./workloads/compile/llvm/run.sh --variant cold_j1          # ~1-2h (single-thread signal)
```

### Windows (probe + self-test only until M5)

```powershell
.\scripts\windows\bootstrap.ps1
.\scripts\common\self_test.ps1
.\scripts\windows\probe.ps1
```

## Layout

```
configs/              # YAML definitions of workloads, versions, iterations
docs/                 # schema, preflight checklists, per-OS notes
results/              # run outputs (JSON) — gitignored except examples
scripts/
  common/             # cross-platform helpers, aggregator
  linux/              # bootstrap + host probe
  macos/              # bootstrap + host probe
  windows/            # bootstrap + host probe (PowerShell)
workloads/            # one folder per benchmark, portable where possible
  synthetic/
  compile/
  runtime/
  devday/
```

## Requirements

- macOS 14+ (Sonoma) — Apple Silicon or Intel
- Linux x86_64 / arm64, kernel 6.x+
- Windows 11 with PowerShell 7+, optional WSL2 for Linux-only workloads

Bootstrap scripts install pinned toolchain versions via `brew` / `apt` / `winget`.

## License

Apache-2.0.
