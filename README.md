# devbench

A cross-platform (macOS / Linux / Windows) benchmark suite for **real developer workloads**:
compilation, test suites, container builds, code search, plus a synthetic baseline.

Built to answer the question "is this machine actually faster for the work I do?" without
trusting a single proprietary score.

See [PLAN.md](./PLAN.md) for design, methodology, and milestones.

## Status

**M3 — Tier 1 synthetic suite + top-level orchestrator runnable.** Tier 2 compile suite next (M4).

### Full pipeline (macOS / Linux / WSL)

```bash
./scripts/macos/bootstrap.sh --baseline           # or scripts/linux/bootstrap.sh
./scripts/run.sh --tier 1 --iterations 3
# -> results/<hostname>-<UTC timestamp>/run.json
```

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
