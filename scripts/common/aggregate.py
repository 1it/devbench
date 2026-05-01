#!/usr/bin/env python3
"""Aggregate devbench runs into normalized cross-machine comparison scores.

The score is intentionally relative. Pick a baseline run/group; each comparable
workload becomes a ratio against that baseline, then ratios are combined with a
weighted geometric mean. A score of 100 means baseline-equivalent, 120 means
20% faster than baseline for the common workload basket.
"""

from __future__ import annotations

import argparse
import csv
import html
import json
import math
import statistics
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

from report import RUN_COLORS, cv_cls, fmt_value, get_meta, metric_value


TIER_NAMES = {
    1: "synthetic",
    2: "compile",
    3: "runtime",
    4: "devday",
    5: "emulation",
    6: "dev_velocity",
    7: "ai_inference",
}

SCORE_PROFILES = {
    # Use this while only tiers 1-3 are implemented. Weights are renormalized
    # over tiers that are present in both baseline and comparison groups.
    "current": {1: 0.25, 2: 0.50, 3: 0.25},
    # Long-term headline mix from PLAN.md once tiers 1-7 exist.
    "headline": {1: 0.10, 2: 0.35, 3: 0.20, 6: 0.20, 7: 0.15},
}

WORKLOAD_CATEGORIES = {
    "synthetic.sysbench_cpu.st": "cpu",
    "synthetic.sysbench_cpu.mt": "cpu",
    "synthetic.fio.4k_qd1": "storage",
    "synthetic.fio.seq": "storage",
    "synthetic.fio.mixed": "storage",
    "synthetic.sevenzip": "compression",
}

CATEGORY_LABELS = {
    "cpu": "CPU",
    "storage": "Storage",
    "compression": "Compression",
}

TIER_CATEGORY_WEIGHTS = {
    # Tier 1 is a sanity/synthetic tier, but CPU should still dominate the
    # headline synthetic score for developer-machine comparisons. Storage can
    # swing wildly, so it remains prominent without overruling CPU outright.
    1: {
        "cpu": 0.50,
        "storage": 0.35,
        "compression": 0.15,
    },
}


@dataclass(frozen=True)
class WorkloadStat:
    test_id: str
    test_name: str
    tier: int
    unit: str
    higher_better: bool
    median: float
    min_value: float
    max_value: float
    cv_pct: float
    n: int
    failed: int


@dataclass
class Group:
    key: str
    label: str
    host: dict
    runtime: dict
    runs: list[dict]
    workloads: dict[str, WorkloadStat]


def load_runs(input_path: Path) -> list[dict]:
    paths: list[Path]
    if input_path.is_file():
        paths = [input_path]
    elif input_path.is_dir():
        paths = sorted(input_path.glob("*/run.json"))
    else:
        raise SystemExit(f"Error: {input_path} is not a file or directory")

    runs = []
    for path in paths:
        try:
            run = json.loads(path.read_text())
            run["_source"] = str(path)
            run["_dir"] = path.parent.name
            runs.append(run)
        except (json.JSONDecodeError, OSError, KeyError) as exc:
            print(f"skip invalid run {path}: {exc}", file=sys.stderr)
    return runs


def host_label(run: dict) -> str:
    host = run["host"]
    cpu = host["cpu"]["model"]
    os_info = host["os"]
    power = run["runtime"].get("power_source", "unknown")
    return (
        f"{host['hostname']} | {cpu} | "
        f"{os_info['name']} {os_info['version']} {os_info['arch']} | {power}"
    )


def machine_key(run: dict) -> str:
    host = run["host"]
    runtime = run["runtime"]
    os_info = host["os"]
    cpu = host["cpu"]
    storage = host.get("storage", {})
    parts = [
        host.get("hostname", ""),
        cpu.get("model", ""),
        str(cpu.get("cores_total", "")),
        os_info.get("name", ""),
        os_info.get("arch", ""),
        runtime.get("power_source", "unknown"),
        storage.get("model", ""),
        storage.get("filesystem", ""),
    ]
    return "\x1f".join(parts)


def group_key(run: dict) -> str:
    host = run["host"]
    runtime = run["runtime"]
    os_info = host["os"]
    cpu = host["cpu"]
    storage = host.get("storage", {})
    parts = [
        host.get("hostname", ""),
        cpu.get("model", ""),
        str(cpu.get("cores_total", "")),
        os_info.get("name", ""),
        os_info.get("version", ""),
        os_info.get("arch", ""),
        runtime.get("power_source", "unknown"),
        runtime.get("config_sha", ""),
        storage.get("model", ""),
        storage.get("filesystem", ""),
    ]
    return "\x1f".join(parts)


def run_started(run: dict) -> str:
    return run.get("runtime", {}).get("started", "")


def select_runs(runs: list[dict], mode: str) -> list[dict]:
    if mode == "session":
        return runs

    by_machine: dict[str, list[dict]] = {}
    for run in runs:
        by_machine.setdefault(machine_key(run), []).append(run)

    selected = []
    for machine_runs in by_machine.values():
        if mode == "latest":
            selected.append(max(machine_runs, key=run_started))
        elif mode == "aggregate":
            selected.extend(machine_runs)
        else:
            raise SystemExit(f"Unknown run selection mode: {mode}")
    return sorted(selected, key=lambda run: (host_label(run), run_started(run)))


def extract_run_workloads(run: dict) -> dict[str, WorkloadStat]:
    workloads = {}
    for result in run.get("results", []):
        test_id = result.get("id")
        if not test_id:
            continue
        values = [
            metric_value(result, iteration)
            for iteration in result.get("iterations", [])
        ]
        values = [value for value in values if value is not None]
        failed = len(result.get("iterations", [])) - len(values)
        if not values:
            continue

        test_name, unit, higher_better = get_meta(test_id)
        med = statistics.median(values)
        sd = statistics.stdev(values) if len(values) > 1 else 0.0
        cv = (sd / med * 100) if med else 0.0
        workloads[test_id] = WorkloadStat(
            test_id=test_id,
            test_name=test_name,
            tier=int(result.get("tier", 0)),
            unit=unit,
            higher_better=higher_better,
            median=med,
            min_value=min(values),
            max_value=max(values),
            cv_pct=cv,
            n=len(values),
            failed=failed,
        )
    return workloads


def combine_workload_stats(test_id: str, stats: list[WorkloadStat]) -> WorkloadStat:
    medians = sorted(stat.median for stat in stats)
    representative = stats[0]
    combined_median = statistics.median(medians)
    combined_sd = statistics.stdev(medians) if len(medians) > 1 else 0.0
    combined_cv = (combined_sd / combined_median * 100) if combined_median else 0.0
    return WorkloadStat(
        test_id=test_id,
        test_name=representative.test_name,
        tier=representative.tier,
        unit=representative.unit,
        higher_better=representative.higher_better,
        median=combined_median,
        min_value=min(stat.min_value for stat in stats),
        max_value=max(stat.max_value for stat in stats),
        cv_pct=max(combined_cv, max(stat.cv_pct for stat in stats)),
        n=sum(stat.n for stat in stats),
        failed=sum(stat.failed for stat in stats),
    )


def build_groups(runs: list[dict], mode: str) -> list[Group]:
    grouped_runs: dict[str, list[dict]] = {}
    key_fn = group_key if mode == "session" else machine_key
    for run in runs:
        grouped_runs.setdefault(key_fn(run), []).append(run)

    groups = []
    for key, group_runs in grouped_runs.items():
        by_test: dict[str, list[WorkloadStat]] = {}
        for run in group_runs:
            for test_id, stat in extract_run_workloads(run).items():
                by_test.setdefault(test_id, []).append(stat)
        workloads = {
            test_id: combine_workload_stats(test_id, stats)
            for test_id, stats in sorted(by_test.items())
        }
        first = group_runs[0]
        groups.append(
            Group(
                key=key,
                label=host_label(first),
                host=first["host"],
                runtime=first["runtime"],
                runs=group_runs,
                workloads=workloads,
            )
        )
    return sorted(groups, key=lambda group: group.label)


def find_baseline_group(groups: list[Group], baseline: Path | None, all_runs: list[dict]) -> Group:
    if baseline is None:
        if not groups:
            raise SystemExit("No groups found")
        return groups[0]

    target = baseline.resolve()
    baseline_machine_key = None
    for run in all_runs:
        if Path(run["_source"]).resolve() == target:
            baseline_machine_key = machine_key(run)
            break

    for group in groups:
        for run in group.runs:
            if Path(run["_source"]).resolve() == target:
                return group
        if baseline_machine_key is not None and group.key == baseline_machine_key:
            return group
    raise SystemExit(f"Baseline run not found in input set: {baseline}")


def ratio_against_baseline(stat: WorkloadStat, base: WorkloadStat) -> float | None:
    if stat.median <= 0 or base.median <= 0:
        return None
    if stat.higher_better:
        return stat.median / base.median
    return base.median / stat.median


def geometric_score(weighted_ratios: Iterable[tuple[float, float]]) -> float | None:
    items = [(ratio, weight) for ratio, weight in weighted_ratios if ratio > 0 and weight > 0]
    if not items:
        return None
    total_weight = sum(weight for _, weight in items)
    if total_weight <= 0:
        return None
    log_sum = sum(math.log(ratio) * weight for ratio, weight in items)
    return 100 * math.exp(log_sum / total_weight)


def score_group(group: Group, baseline: Group, profile: dict[int, float]) -> dict:
    common_ids = sorted(set(group.workloads) & set(baseline.workloads))
    workload_rows = []
    ratios_by_tier: dict[int, list[float]] = {}

    for test_id in common_ids:
        stat = group.workloads[test_id]
        base = baseline.workloads[test_id]
        ratio = ratio_against_baseline(stat, base)
        if ratio is None:
            continue
        ratios_by_tier.setdefault(stat.tier, []).append(ratio)
        workload_rows.append({
            "test_id": test_id,
            "test_name": stat.test_name,
            "tier": stat.tier,
            "unit": stat.unit,
            "higher_better": stat.higher_better,
            "baseline_median": base.median,
            "median": stat.median,
            "ratio": ratio,
            "score": ratio * 100,
            "cv_pct": stat.cv_pct,
            "baseline_cv_pct": base.cv_pct,
            "n": stat.n,
            "failed": stat.failed,
        })

    ratios_by_category: dict[str, list[float]] = {}
    for row in workload_rows:
        category = WORKLOAD_CATEGORIES.get(row["test_id"])
        if category:
            ratios_by_category.setdefault(category, []).append(row["ratio"])

    category_scores = {}
    for category, ratios in sorted(ratios_by_category.items()):
        score = geometric_score((ratio, 1.0) for ratio in ratios)
        if score is not None:
            category_scores[category] = {
                "name": CATEGORY_LABELS.get(category, category.replace("_", " ").title()),
                "score": score,
                "workloads": len(ratios),
            }

    tier_scores = {}
    for tier, ratios in sorted(ratios_by_tier.items()):
        score_method = "workload_equal"
        category_weights = None
        score = None
        if tier in TIER_CATEGORY_WEIGHTS:
            weighted_categories = []
            present_weights = {}
            for category, weight in TIER_CATEGORY_WEIGHTS[tier].items():
                category_s = category_scores.get(category)
                if category_s is None:
                    continue
                weighted_categories.append((category_s["score"] / 100, weight))
                present_weights[category] = weight
            score = geometric_score(weighted_categories)
            if score is not None:
                score_method = "category_weighted"
                category_weights = present_weights

        if score is None:
            score = geometric_score((ratio, 1.0) for ratio in ratios)

        if score is not None:
            tier_entry = {
                "tier": tier,
                "name": TIER_NAMES.get(tier, f"tier_{tier}"),
                "score": score,
                "workloads": len(ratios),
                "weight": profile.get(tier, 0.0),
                "score_method": score_method,
            }
            if category_weights is not None:
                tier_entry["category_weights"] = category_weights
            tier_scores[str(tier)] = tier_entry

    overall_items = []
    for tier_s in tier_scores.values():
        weight = profile.get(tier_s["tier"], 0.0)
        if weight > 0:
            overall_items.append((tier_s["score"] / 100, weight))
    overall_score = geometric_score(overall_items)

    noisy = [
        row["test_id"]
        for row in workload_rows
        if row["cv_pct"] > 10 or row["baseline_cv_pct"] > 10
    ]
    warn = [
        row["test_id"]
        for row in workload_rows
        if row["test_id"] not in noisy
        and (row["cv_pct"] > 5 or row["baseline_cv_pct"] > 5)
    ]

    return {
        "group_key": group.key,
        "label": group.label,
        "is_baseline": group.key == baseline.key,
        "runs": [run["_source"] for run in group.runs],
        "run_count": len(group.runs),
        "overall_score": overall_score,
        "tier_scores": tier_scores,
        "category_scores": category_scores,
        "coverage": {
            "common_workloads": len(workload_rows),
            "baseline_workloads": len(baseline.workloads),
            "group_workloads": len(group.workloads),
        },
        "warnings": {
            "cv_gt_5_pct": warn,
            "cv_gt_10_pct": noisy,
        },
        "workloads": workload_rows,
    }


def fmt_score(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.2f}"


def write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2) + "\n")


def write_csv(path: Path, scored_groups: list[dict]) -> None:
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "group",
                "is_baseline",
                "overall_score",
                "tier",
                "test_id",
                "test_name",
                "median",
                "baseline_median",
                "unit",
                "ratio",
                "score",
                "cv_pct",
                "baseline_cv_pct",
                "n",
                "failed",
            ],
        )
        writer.writeheader()
        for group in scored_groups:
            for row in group["workloads"]:
                writer.writerow({
                    "group": group["label"],
                    "is_baseline": group["is_baseline"],
                    "overall_score": fmt_score(group["overall_score"]),
                    "tier": row["tier"],
                    "test_id": row["test_id"],
                    "test_name": row["test_name"],
                    "median": f"{row['median']:.6g}",
                    "baseline_median": f"{row['baseline_median']:.6g}",
                    "unit": row["unit"],
                    "ratio": f"{row['ratio']:.6f}",
                    "score": f"{row['score']:.3f}",
                    "cv_pct": f"{row['cv_pct']:.3f}",
                    "baseline_cv_pct": f"{row['baseline_cv_pct']:.3f}",
                    "n": row["n"],
                    "failed": row["failed"],
                })


def markdown_table(headers: list[str], rows: list[list[str]]) -> str:
    def cell(value: str) -> str:
        return str(value).replace("\n", " ").replace("|", r"\|")

    lines = [
        "| " + " | ".join(cell(header) for header in headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(cell(value) for value in row) + " |")
    return "\n".join(lines)


def write_markdown(path: Path, data: dict, scored_groups: list[dict]) -> None:
    baseline = data["baseline"]
    generated = data["generated"]
    profile = data["score_profile"]
    run_selection = data["run_selection"]

    summary_rows = []
    for group in sorted(
        scored_groups,
        key=lambda item: item["overall_score"] if item["overall_score"] is not None else -1,
        reverse=True,
    ):
        coverage = group["coverage"]
        tier_bits = []
        for tier, tier_s in sorted(group["tier_scores"].items(), key=lambda item: int(item[0])):
            tier_bits.append(f"T{tier} {fmt_score(tier_s['score'])}")
        category_bits = []
        for category_s in group["category_scores"].values():
            category_bits.append(f"{category_s['name']} {fmt_score(category_s['score'])}")
        warnings = []
        if group["warnings"]["cv_gt_10_pct"]:
            warnings.append(f"noisy>{len(group['warnings']['cv_gt_10_pct'])}")
        if group["warnings"]["cv_gt_5_pct"]:
            warnings.append(f"warn>{len(group['warnings']['cv_gt_5_pct'])}")
        summary_rows.append([
            group["label"],
            fmt_score(group["overall_score"]),
            ", ".join(tier_bits) or "n/a",
            ", ".join(category_bits) or "n/a",
            f"{coverage['common_workloads']}/{coverage['baseline_workloads']}",
            str(group["run_count"]),
            ", ".join(warnings) or "-",
        ])

    sections = [
        "# devbench comparison",
        "",
        f"Generated: {generated}",
        f"Score profile: `{profile}`",
        f"Run selection: `{run_selection}`",
        f"Baseline: {baseline['label']}",
        "",
        "Scores are relative to the baseline. `100` means baseline-equivalent; `120` means 20% faster across the common weighted workload basket.",
        "",
        markdown_table(
            ["Machine group", "Score", "Tier scores", "Category scores", "Coverage", "Runs", "Warnings"],
            summary_rows,
        ),
        "",
    ]

    for group in scored_groups:
        rows = []
        for row in sorted(group["workloads"], key=lambda item: (item["tier"], item["test_id"])):
            rows.append([
                f"T{row['tier']}",
                row["test_id"],
                fmt_value(row["median"], row["unit"]),
                fmt_value(row["baseline_median"], row["unit"]),
                f"{row['score']:.1f}",
                f"{row['cv_pct']:.1f} / {row['baseline_cv_pct']:.1f}",
            ])
        sections.extend([
            f"## {group['label']}",
            "",
            markdown_table(
                ["Tier", "Workload", "Median", "Baseline", "Score", "CV% / base"],
                rows,
            ),
            "",
        ])

    path.write_text("\n".join(sections))


def score_class(score: float | None) -> str:
    if score is None:
        return "score-neutral"
    if score >= 105:
        return "score-good"
    if score <= 95:
        return "score-bad"
    return "score-neutral"


def warning_text(group: dict) -> str:
    noisy = len(group["warnings"]["cv_gt_10_pct"])
    warn = len(group["warnings"]["cv_gt_5_pct"])
    parts = []
    if noisy:
        parts.append(f"{noisy} noisy")
    if warn:
        parts.append(f"{warn} warned")
    return ", ".join(parts) if parts else "-"


def compact_label(label: str) -> str:
    parts = label.split(" | ")
    if len(parts) >= 2:
        return f"{parts[0]} · {parts[1]}"
    return label


def score_width(score: float | None, scale: float) -> float:
    if score is None or scale <= 0:
        return 0
    return max(0, min(score / scale * 100, 100))


def build_score_bar(
    *,
    label: str,
    color: str,
    score: float | None,
    scale: float,
    meta: str,
    escape_meta: bool = True,
) -> str:
    pct = score_width(score, scale)
    value = fmt_score(score)
    meta_html = html.escape(meta) if escape_meta else meta
    return (
        '<div class="bar-row">'
        f'  <span class="bar-label" title="{html.escape(label)}">'
        f'    <span class="color-dot" style="background:{color}"></span>{html.escape(compact_label(label))}'
        '  </span>'
        '  <div class="bar-track">'
        f'    <div class="bar-fill" style="width:{pct:.1f}%;background:{color}">'
        f'      <span class="bar-value">{html.escape(value)}</span>'
        '    </div>'
        '  </div>'
        f'  <span class="bar-meta">{meta_html}</span>'
        '</div>'
    )


def build_html(data: dict, scored_groups: list[dict]) -> str:
    ranked_groups = sorted(
        scored_groups,
        key=lambda item: item["overall_score"] if item["overall_score"] is not None else -1,
        reverse=True,
    )
    group_colors = {
        group["group_key"]: RUN_COLORS[index % len(RUN_COLORS)]
        for index, group in enumerate(ranked_groups)
    }
    max_overall = max([group["overall_score"] or 0 for group in ranked_groups] + [100])

    summary_bars = []
    summary_rows = []
    for group in ranked_groups:
        coverage = group["coverage"]
        score = group["overall_score"]
        color = group_colors[group["group_key"]]
        tier_bits = []
        for tier, tier_s in sorted(group["tier_scores"].items(), key=lambda item: int(item[0])):
            tier_bits.append(
                f'<span class="tier-pill">T{html.escape(tier)} {fmt_score(tier_s["score"])}</span>'
            )
        baseline_badge = '<span class="baseline-badge">baseline</span>' if group["is_baseline"] else ""
        summary_bars.append(build_score_bar(
            label=group["label"],
            color=color,
            score=score,
            scale=max_overall,
            meta=f"coverage {coverage['common_workloads']}/{coverage['baseline_workloads']}",
        ))
        summary_rows.append(
            "<tr>"
            f'<td><span class="color-dot" style="background:{color}"></span><strong>{html.escape(group["label"])}</strong> {baseline_badge}</td>'
            f'<td class="num {score_class(score)}">{fmt_score(score)}</td>'
            f"<td>{''.join(tier_bits) or 'n/a'}</td>"
            f'<td class="num">{coverage["common_workloads"]}/{coverage["baseline_workloads"]}</td>'
            f'<td class="num">{group["run_count"]}</td>'
            f'<td>{html.escape(warning_text(group))}</td>'
            "</tr>"
        )

    tier_cards = []
    tier_ids = sorted(
        {int(tier) for group in scored_groups for tier in group["tier_scores"]},
    )
    for tier_id in tier_ids:
        tier_rows = []
        tier_scores = [
            group["tier_scores"].get(str(tier_id), {}).get("score")
            for group in ranked_groups
        ]
        scale = max([score or 0 for score in tier_scores] + [100])
        for group in ranked_groups:
            tier_s = group["tier_scores"].get(str(tier_id))
            if not tier_s:
                continue
            method = "category-weighted" if tier_s.get("score_method") == "category_weighted" else "equal-weight"
            tier_rows.append(build_score_bar(
                label=group["label"],
                color=group_colors[group["group_key"]],
                score=tier_s["score"],
                scale=scale,
                meta=f'{tier_s["workloads"]} workloads · {method}',
            ))
        tier_name = TIER_NAMES.get(tier_id, f"tier_{tier_id}")
        if tier_id in TIER_CATEGORY_WEIGHTS:
            weights_text = ", ".join(
                f"{CATEGORY_LABELS.get(category, category)} {weight * 100:.0f}%"
                for category, weight in TIER_CATEGORY_WEIGHTS[tier_id].items()
            )
            unit = f"normalized score · category-weighted: {weights_text}"
        else:
            unit = "normalized score — higher is better"
        tier_cards.append(
            '<div class="card">'
            '<div class="card-header">'
            f'<div><h2>Tier {tier_id}: {html.escape(tier_name)}</h2><span class="unit">{html.escape(unit)}</span></div>'
            '</div>'
            f'<div class="bars">{"".join(tier_rows)}</div>'
            '</div>'
        )

    category_cards = []
    category_ids = sorted(
        {category for group in scored_groups for category in group["category_scores"]},
    )
    for category in category_ids:
        category_rows = []
        category_scores = [
            group["category_scores"].get(category, {}).get("score")
            for group in ranked_groups
        ]
        scale = max([score or 0 for score in category_scores] + [100])
        for group in ranked_groups:
            category_s = group["category_scores"].get(category)
            if not category_s:
                continue
            category_rows.append(build_score_bar(
                label=group["label"],
                color=group_colors[group["group_key"]],
                score=category_s["score"],
                scale=scale,
                meta=f'{category_s["workloads"]} workloads',
            ))
        category_name = CATEGORY_LABELS.get(category, category.replace("_", " ").title())
        category_cards.append(
            '<div class="card">'
            '<div class="card-header">'
            f'<div><h2>{html.escape(category_name)}</h2><span class="unit">category score — higher is better</span></div>'
            '</div>'
            f'<div class="bars">{"".join(category_rows)}</div>'
            '</div>'
        )

    workload_order = []
    by_workload: dict[str, list[dict]] = {}
    for group in scored_groups:
        for row in group["workloads"]:
            if row["test_id"] not in by_workload:
                workload_order.append(row["test_id"])
            enriched = dict(row)
            enriched["group_key"] = group["group_key"]
            enriched["group_label"] = group["label"]
            enriched["color"] = group_colors[group["group_key"]]
            by_workload.setdefault(row["test_id"], []).append(enriched)

    workload_cards = []
    table_rows = []
    for test_id in workload_order:
        rows = sorted(
            by_workload[test_id],
            key=lambda item: ranked_groups.index(next(g for g in ranked_groups if g["group_key"] == item["group_key"])),
        )
        first = rows[0]
        scale = max([row["score"] for row in rows] + [100])
        direction = "higher is better" if first["higher_better"] else "lower is better"
        bars = []
        stat_lines = []
        for row in rows:
            cv_c = cv_cls(row["cv_pct"])
            cv_tag = f' <span class="bar-cv {cv_c}">CV {row["cv_pct"]:.1f}%</span>' if row["cv_pct"] > 3 else ""
            fail_tag = f' <span class="bar-failed">failed {row["failed"]}</span>' if row["failed"] else ""
            bars.append(build_score_bar(
                label=row["group_label"],
                color=row["color"],
                score=row["score"],
                scale=scale,
                meta=f'{fmt_value(row["median"], row["unit"])}{cv_tag}{fail_tag}',
                escape_meta=False,
            ))
            stat_lines.append(
                '<div class="stat-line">'
                f'<span class="color-dot" style="background:{row["color"]}"></span>'
                f'<span>score <strong>{row["score"]:.1f}</strong></span>'
                '<span class="sep">|</span>'
                f'<span>median <strong>{html.escape(fmt_value(row["median"], row["unit"]))}</strong></span>'
                '<span class="sep">|</span>'
                f'<span>baseline {html.escape(fmt_value(row["baseline_median"], row["unit"]))}</span>'
                '<span class="sep">|</span>'
                f'<span class="{cv_c}">CV {row["cv_pct"]:.1f}%</span>'
                '</div>'
            )
            table_rows.append(
                '<tr>'
                f'<td>{html.escape(first["test_name"])}</td>'
                f'<td><span class="color-dot" style="background:{row["color"]}"></span>{html.escape(row["group_label"])}</td>'
                f'<td class="num">{row["score"]:.1f}</td>'
                f'<td class="num">{html.escape(fmt_value(row["median"], row["unit"]))}</td>'
                f'<td class="num">{html.escape(fmt_value(row["baseline_median"], row["unit"]))}</td>'
                f'<td class="num {cv_c}">{row["cv_pct"]:.1f}</td>'
                f'<td class="num">{row["n"]}</td>'
                f'<td class="num">{row["failed"]}</td>'
                '</tr>'
            )
        workload_cards.append(
            '<div class="card">'
            '<div class="card-header">'
            f'<div><h2>{html.escape(first["test_name"])}</h2><span class="unit">T{first["tier"]} · normalized score · {direction}</span></div>'
            '</div>'
            f'<div class="bars">{"".join(bars)}</div>'
            f'<div class="stat-block">{"".join(stat_lines)}</div>'
            '</div>'
        )

    generated = html.escape(data["generated"])
    profile = html.escape(data["score_profile"])
    run_selection = html.escape(data["run_selection"])
    baseline = html.escape(data["baseline"]["label"])
    weights = ", ".join(
        f"T{html.escape(tier)} {weight * 100:.0f}%"
        for tier, weight in sorted(data["score_profile_weights"].items(), key=lambda item: int(item[0]))
    )

    return HTML_TEMPLATE.format(
        generated=generated,
        profile=profile,
        run_selection=run_selection,
        baseline=baseline,
        weights=html.escape(weights),
        summary_bars="".join(summary_bars),
        summary_rows="".join(summary_rows),
        tier_cards="".join(tier_cards),
        category_cards="".join(category_cards),
        workload_cards="".join(workload_cards),
        table_rows="".join(table_rows),
    )


def write_html(path: Path, data: dict, scored_groups: list[dict]) -> None:
    path.write_text(build_html(data, scored_groups))


HTML_TEMPLATE = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>devbench comparison</title>
<style>
:root {{
  --bg: #0d1117; --fg: #c9d1d9; --fg2: #8b949e; --card: #161b22;
  --border: #30363d; --track: #21262d;
  --green: #3fb950; --yellow: #d29922; --red: #f85149;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
}}
*, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
body {{ background: var(--bg); color: var(--fg); padding: 2rem 2.5rem; line-height: 1.55; }}

/* --- Header --- */
h1 {{ font-size: 1.8rem; font-weight: 700; }}
.subtitle {{ color: var(--fg2); margin-bottom: 2rem; font-size: .92rem; }}

/* --- Host card --- */
.host-card {{
  background: var(--card); border: 1px solid var(--border); border-radius: 8px;
  padding: 1.2rem 1.5rem; margin-bottom: 1rem;
}}
.host-grid {{
  display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: .8rem 2rem;
}}
.host-grid dt {{ color: var(--fg2); font-size: .72rem; text-transform: uppercase; letter-spacing: .06em; }}
.host-grid dd {{ font-weight: 600; font-size: .95rem; }}

/* --- Tables --- */
.section-label {{ font-size: 1.15rem; font-weight: 600; margin: 1.8rem 0 .6rem; }}
.raw-table {{ width: 100%; border-collapse: collapse; font-size: .85rem; margin-top: .5rem; }}
.raw-table th {{
  text-align: left; padding: .55rem .8rem; color: var(--fg2); font-weight: 600;
  font-size: .72rem; text-transform: uppercase; letter-spacing: .05em;
  border-bottom: 2px solid var(--border); position: sticky; top: 0; background: var(--bg);
}}
.raw-table td {{ padding: .5rem .8rem; border-bottom: 1px solid var(--border); }}
.raw-table .num {{ text-align: right; font-variant-numeric: tabular-nums; }}

/* --- Color dot --- */
.color-dot {{
  display: inline-block; width: 10px; height: 10px; border-radius: 50%;
  margin-right: 6px; vertical-align: middle; flex-shrink: 0;
}}

/* --- Cards grid --- */
.grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(480px, 1fr)); gap: 1.2rem; }}
.card {{
  background: var(--card); border: 1px solid var(--border); border-radius: 8px;
  padding: 1.3rem 1.5rem;
}}
.card-header {{ display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 1rem; }}
.card h2 {{ font-size: 1.05rem; font-weight: 600; }}
.unit {{ color: var(--fg2); font-size: .78rem; margin-top: 2px; }}

/* --- Badges --- */
.baseline-badge {{
  display: inline-block; border: 1px solid rgba(63,185,80,.35); border-radius: 999px;
  padding: .08rem .45rem; margin-left: .35rem; color: var(--green); font-size: .75rem;
}}
.tier-pill {{
  display: inline-block; border: 1px solid var(--border); border-radius: 999px;
  padding: .08rem .45rem; margin: .1rem .2rem .1rem 0; color: var(--fg2); font-size: .75rem;
}}
.score-good {{ color: var(--green); font-weight: 700; }}
.score-bad {{ color: var(--red); font-weight: 700; }}
.score-neutral {{ color: var(--fg); font-weight: 700; }}

/* --- Bars --- */
.bars {{ margin-bottom: .8rem; }}
.bar-row {{ display: flex; align-items: center; gap: .6rem; margin-bottom: .5rem; }}
.bar-label {{
  min-width: 220px; max-width: 220px; font-size: .8rem; white-space: nowrap;
  overflow: hidden; text-overflow: ellipsis; display: flex; align-items: center;
}}
.bar-track {{
  flex: 1; height: 30px; background: var(--track); border-radius: 4px;
  position: relative; overflow: hidden;
}}
.bar-fill {{
  height: 100%; min-width: 1px; border-radius: 4px; display: flex; align-items: center;
  padding: 0 10px; transition: width .3s ease;
}}
.bar-value {{ font-size: .82rem; font-weight: 700; color: #fff; white-space: nowrap; }}
.bar-meta {{ font-size: .75rem; color: var(--fg2); min-width: 120px; text-align: right; }}
.bar-cv {{ margin-left: 4px; }}
.bar-failed {{ margin-left: 4px; color: var(--red); font-weight: 600; }}

/* --- Stat block --- */
.stat-block {{ border-top: 1px solid var(--border); padding-top: .7rem; }}
.stat-line {{
  display: flex; align-items: center; gap: .5rem; font-size: .78rem; color: var(--fg2);
  padding: 2px 0; flex-wrap: wrap;
}}
.stat-line strong {{ color: var(--fg); }}
.sep {{ opacity: .3; }}
.cv-warn {{ color: var(--yellow); font-weight: 600; }}
.cv-bad {{ color: var(--red); font-weight: 600; }}

/* --- Reading guide --- */
.guide {{
  background: var(--card); border: 1px solid var(--border); border-radius: 8px;
  padding: 1rem 1.3rem; margin-bottom: 1.5rem; font-size: .82rem; color: var(--fg2); line-height: 1.7;
}}
.guide strong {{ color: var(--fg); }}
.guide code {{ background: var(--track); padding: 1px 5px; border-radius: 3px; font-size: .8rem; }}

footer {{ margin-top: 3rem; color: #484f58; font-size: .78rem; text-align: center; }}
</style>
</head>
<body>
<h1>devbench comparison</h1>
<p class="subtitle">Generated {generated} &mdash; score profile <code>{profile}</code> &mdash; run selection <code>{run_selection}</code></p>

<div class="host-card">
  <dl class="host-grid">
    <div><dt>Baseline</dt><dd>{baseline}</dd></div>
    <div><dt>Weights</dt><dd>{weights}</dd></div>
    <div><dt>Run selection</dt><dd>{run_selection}</dd></div>
    <div><dt>Score</dt><dd>100 = baseline-equivalent</dd></div>
  </dl>
</div>

<div class="guide">
  <strong>How to read:</strong>
  Bars show the <strong>normalized score</strong> versus the selected baseline.
  <code>100</code> is baseline-equivalent; <code>120</code> is 20% faster.
  Workload cards also show the raw median and <code>CV</code>; yellow means noisy
  (<code>&gt;5%</code>), red means very noisy (<code>&gt;10%</code>).
</div>

<div class="card" style="margin-bottom:1.5rem">
  <div class="card-header">
    <div><h2>Overall Score</h2><span class="unit">weighted geometric mean — higher is better</span></div>
  </div>
  <div class="bars">{summary_bars}</div>
  <table class="raw-table">
<thead><tr>
  <th>Machine group</th><th class="num">Score</th><th>Tier scores</th><th class="num">Coverage</th><th class="num">Runs</th><th>Warnings</th>
</tr></thead>
<tbody>{summary_rows}</tbody>
</table>
</div>

<h3 class="section-label">Tier Scores</h3>
<div class="grid">
{tier_cards}
</div>

<h3 class="section-label">Category Scores</h3>
<div class="grid">
{category_cards}
</div>

<h3 class="section-label">Workload Scores</h3>
<div class="grid">
{workload_cards}
</div>

<h3 class="section-label" style="margin-top:2.5rem">Raw data</h3>
<table class="raw-table">
<thead><tr>
  <th>Test</th><th>Machine group</th><th class="num">Score</th><th class="num">Median</th>
  <th class="num">Baseline</th><th class="num">CV%</th><th class="num">N</th><th class="num">Failed</th>
</tr></thead>
<tbody>{table_rows}</tbody>
</table>

<footer>devbench aggregate comparison</footer>
</body>
</html>
"""


def main() -> None:
    parser = argparse.ArgumentParser(description="Aggregate devbench runs into comparison scores")
    parser.add_argument(
        "results",
        nargs="?",
        default="results",
        help="Directory containing result folders, or a single run.json",
    )
    parser.add_argument(
        "--baseline",
        help="Baseline run.json. Defaults to the first machine group after sorting.",
    )
    parser.add_argument(
        "--profile",
        choices=sorted(SCORE_PROFILES),
        default="current",
        help="Score weighting profile",
    )
    parser.add_argument(
        "--run-selection",
        choices=["latest", "aggregate", "session"],
        default="latest",
        help=(
            "How to handle multiple runs from the same machine: latest keeps only "
            "the newest run, aggregate combines all matching machine runs, session "
            "keeps config/session groups separate"
        ),
    )
    parser.add_argument(
        "--out-dir",
        default="results/aggregate",
        help="Directory for scores.json, summary.csv, comparison.md, and comparison.html",
    )
    args = parser.parse_args()

    runs = load_runs(Path(args.results))
    if not runs:
        raise SystemExit(f"No run.json files found under {args.results}")

    selected_runs = select_runs(runs, args.run_selection)
    groups = build_groups(selected_runs, args.run_selection)
    baseline = find_baseline_group(groups, Path(args.baseline) if args.baseline else None, runs)
    profile = SCORE_PROFILES[args.profile]

    scored_groups = [score_group(group, baseline, profile) for group in groups]
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    data = {
        "generated": generated,
        "score_profile": args.profile,
        "score_profile_weights": {str(k): v for k, v in profile.items()},
        "run_selection": args.run_selection,
        "baseline": {
            "group_key": baseline.key,
            "label": baseline.label,
            "runs": [run["_source"] for run in baseline.runs],
        },
        "groups": scored_groups,
    }

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    write_json(out_dir / "scores.json", data)
    write_csv(out_dir / "summary.csv", scored_groups)
    write_markdown(out_dir / "comparison.md", data, scored_groups)
    write_html(out_dir / "comparison.html", data, scored_groups)

    print(
        f"Loaded {len(runs)} run(s), selected {len(selected_runs)} via {args.run_selection}, "
        f"grouped into {len(groups)} machine group(s)",
        file=sys.stderr,
    )
    print(f"Baseline: {baseline.label}", file=sys.stderr)
    print(f"Wrote {out_dir / 'scores.json'}", file=sys.stderr)
    print(f"Wrote {out_dir / 'summary.csv'}", file=sys.stderr)
    print(f"Wrote {out_dir / 'comparison.md'}", file=sys.stderr)
    print(f"Wrote {out_dir / 'comparison.html'}", file=sys.stderr)


if __name__ == "__main__":
    main()
