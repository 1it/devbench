# Scoring and machine comparison

`devbench` scores are relative to an explicit baseline machine group. They are
not proprietary absolute points.

For each workload, the aggregator first computes the median metric for each run.
Repeated runs from the same machine/OS/power/config group are combined by taking
the median of those run medians.

Workload ratios are normalized by direction:

```text
higher-is-better: ratio = machine_metric / baseline_metric
lower-is-better:  ratio = baseline_metric / machine_metric
```

Each ratio is converted to a score where `100` means baseline-equivalent. A
workload score of `120` means 20% faster than the baseline for that workload.

Tier and overall scores use a weighted geometric mean:

```text
score = 100 * exp(weighted_mean(log(ratio)))
```

The geometric mean keeps mixed units comparable and prevents one very large
outlier from dominating the result.

## Profiles

The `current` profile is intended for the implemented tiers:

| Tier | Weight |
|---|---:|
| Tier 1 synthetic | 25% |
| Tier 2 compile | 50% |
| Tier 3 runtime/tests | 25% |

Tier 1 is category-weighted before it contributes to the profile score:

| Category | Weight |
|---|---:|
| CPU | 50% |
| Storage | 35% |
| Compression | 15% |

This prevents the three fio storage workloads from accidentally dominating the
synthetic score just because there are more of them.

The `headline` profile is the intended long-term mix once tiers 6 and 7 are
implemented:

| Tier | Weight |
|---|---:|
| Tier 1 synthetic | 10% |
| Tier 2 compile | 35% |
| Tier 3 runtime/tests | 20% |
| Tier 6 dev velocity | 20% |
| Tier 7 local AI | 15% |

Weights are renormalized over tiers that exist in both the baseline and compared
machine group. The report always shows workload coverage so partial scores are
not mistaken for full-suite results.

## Quality flags

The aggregator includes workloads with high variance, but flags them:

- `CV > 5%`: warning
- `CV > 10%`: noisy, treat with suspicion

The publishable standard is still the methodology in `PLAN.md`: only claim a
difference when median delta is greater than 5% and IQRs do not overlap.

## Usage

```bash
./scripts/compare.sh results \
  --baseline results/MACHINE-YYYYMMDD-HHMMSS/run.json \
  --out-dir results/aggregate
```

Add `--open` to open the HTML report after generation.

By default the comparison uses `--run-selection latest`, which keeps only the
newest result for each machine identity. Other modes:

- `--run-selection aggregate`: combine repeated runs from the same machine.
- `--run-selection session`: keep config/session groups separate for debugging.

Outputs:

- `results/aggregate/scores.json`
- `results/aggregate/summary.csv`
- `results/aggregate/comparison.md`
- `results/aggregate/comparison.html`
