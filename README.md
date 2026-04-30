# devbench

A cross-platform (macOS / Linux / Windows) benchmark suite for **real developer workloads**:
compilation, test suites, container builds, code search, plus a synthetic baseline.

Built to answer the question "is this machine actually faster for the work I do?" without
trusting a single proprietary score.

See [PLAN.md](./PLAN.md) for design, methodology, and milestones.

## Status

**M1 — scaffolding.** Nothing runnable yet.

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
