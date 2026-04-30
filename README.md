# devbench

A cross-platform (macOS / Linux / Windows) benchmark suite for **real developer workloads**:
compilation, test suites, container builds, code search, plus a synthetic baseline.

Built to answer the question "is this machine actually faster for the work I do?" without
trusting a single proprietary score.

See [PLAN.md](./PLAN.md) for design, methodology, and milestones.

## Status

**M2 — host probes + self-test + bootstrap scaffolding runnable.** Tier-1 synthetic suite next (M3).

Runnable today:

```bash
# macOS (works; probe + self-test validated on M1 Pro)
./scripts/macos/bootstrap.sh --baseline
./scripts/common/self_test.sh          # calibration, fails if CV > 3%
./scripts/macos/probe.sh               # emits host JSON
./scripts/common/runtime_init.sh --config configs/default.yaml

# Linux (written, untested here — apt/dnf both supported)
./scripts/linux/bootstrap.sh --baseline
./scripts/common/self_test.sh
./scripts/linux/probe.sh

# Windows (written, untested here — PS7 + winget)
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

## Quick start (planned)

```bash
# macOS / Linux
./scripts/run.sh --tier 1,2 --iterations 3 --output results/

# Windows (PowerShell 7+)
./scripts/run.ps1 -Tier 1,2 -Iterations 3 -Output results/
```

## Requirements (planned)

- macOS 14+ (Sonoma) — Apple Silicon or Intel
- Linux x86_64 / arm64, kernel 6.x+
- Windows 11 with PowerShell 7+, optional WSL2 for Linux-only workloads

Bootstrap scripts install pinned toolchain versions via `brew` / `apt` / `winget`.

## License

TBD.
