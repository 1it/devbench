#!/usr/bin/env python3
"""Generate a self-contained HTML report from devbench run.json files.

Usage:
    python3 scripts/common/report.py [results_dir]
    python3 scripts/common/report.py results --out results/report.html
"""

import argparse
import html
import json
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Metric definitions
# ---------------------------------------------------------------------------

METRIC_EXTRACTORS = {
    "synthetic.sysbench_cpu": lambda it: it["extra"]["events_per_sec"],
    "synthetic.sevenzip": lambda it: it["extra"]["total_mips"],
    "synthetic.fio.4k_qd1": lambda it: it["extra"]["read"]["iops"],
    "synthetic.fio.seq": lambda it: it["extra"]["read"]["bw_kib_s"] / 1024,
    "synthetic.fio.mixed": lambda it: (
        it["extra"]["read"]["iops"] + it["extra"]["write"]["iops"]
    ),
}

WORKLOAD_META = {
    # Tier 1: primary workload-specific score. Higher is better.
    "synthetic.sysbench_cpu.st": ("CPU Single-Thread", "events/s", True),
    "synthetic.sysbench_cpu.mt": ("CPU Multi-Thread", "events/s", True),
    "synthetic.sevenzip": ("7-Zip Compress + Decompress", "MIPS", True),
    "synthetic.fio.4k_qd1": ("SSD 4K Random Read QD1", "IOPS", True),
    "synthetic.fio.seq": ("SSD Sequential Read", "MiB/s", True),
    "synthetic.fio.mixed": ("SSD Mixed R/W", "IOPS (r+w)", True),

    # Tier 2: real compile tasks. Wall-clock seconds, lower is better.
    "compile.ripgrep.cold": ("ripgrep Cold Build", "seconds", False),
    "compile.ripgrep.warm": ("ripgrep Warm Build", "seconds", False),
    "compile.ripgrep.incremental": ("ripgrep Incremental Build", "seconds", False),
    "compile.ripgrep.cold_mold": ("ripgrep Cold Build (mold)", "seconds", False),
    "compile.typescript.tsc_cold": ("TypeScript tsc Cold Build", "seconds", False),
    "compile.typescript.tsc_incremental": ("TypeScript tsc Incremental Build", "seconds", False),
    "compile.typescript.tsgo_typecheck": ("TypeScript tsgo Type-check", "seconds", False),
    "compile.kubernetes.cold": ("Kubernetes Cold Build", "seconds", False),
    "compile.kubernetes.warm": ("Kubernetes Warm Build", "seconds", False),
    "compile.llvm.cold_jN": ("LLVM/Clang Cold Build -jN", "seconds", False),
    "compile.llvm.cold_j1": ("LLVM/Clang Cold Build -j1", "seconds", False),
    "compile.llvm.warm_jN": ("LLVM/Clang Warm Build -jN", "seconds", False),
    "compile.llvm.incremental": ("LLVM/Clang Incremental Build", "seconds", False),
    "compile.duckdb.cold": ("DuckDB Cold Build", "seconds", False),
    "compile.linux_kernel.cold_jN": ("Linux Kernel Cold Build -jN", "seconds", False),
    "compile.linux_kernel.incremental": ("Linux Kernel Incremental Build", "seconds", False),

    # Tier 3: runtime/test tasks. Wall-clock seconds, lower is better.
    "runtime.pytest_pandas.parallel": ("pandas pytest (parallel)", "seconds", False),
    "runtime.pytest_pandas.serial": ("pandas pytest (serial)", "seconds", False),
    "runtime.vite_tests": ("Vite Test Suite", "seconds", False),
    "runtime.renaissance": ("Renaissance JVM Subset", "seconds", False),
    "runtime.docker_build_rust.cold": ("Docker Rust Image Build (cold)", "seconds", False),
    "runtime.docker_build_rust.warm": ("Docker Rust Image Build (warm)", "seconds", False),
}

RUN_COLORS = [
    "#58a6ff", "#3fb950", "#d29922", "#f778ba",
    "#bc8cff", "#79c0ff", "#56d364", "#e3b341",
]


def get_extractor(test_id: str):
    for prefix, fn in METRIC_EXTRACTORS.items():
        if test_id.startswith(prefix):
            return fn
    return None


def get_meta(test_id: str):
    if test_id in WORKLOAD_META:
        return WORKLOAD_META[test_id]
    for prefix, meta in WORKLOAD_META.items():
        if test_id.startswith(prefix):
            return meta
    if test_id.startswith(("compile.", "runtime.")):
        return (test_id, "seconds", False)
    return (test_id, "", True)


def metric_value(result: dict, iteration: dict) -> float | None:
    extractor = get_extractor(result["id"])
    if extractor:
        try:
            return extractor(iteration)
        except (KeyError, TypeError):
            return None

    # Tier 2/3 workload scripts use time_run.sh; wall-clock seconds is the
    # canonical comparable metric. run_tier.sh records failed iterations as
    # wallclock_s=null, so filter those out here and surface failed=N in the UI.
    wallclock = iteration.get("wallclock_s")
    if isinstance(wallclock, (int, float)):
        return float(wallclock)
    return None


def fmt_num(n: float) -> str:
    if abs(n) >= 1_000_000:
        return f"{n / 1_000_000:,.2f}M"
    if abs(n) >= 1_000:
        return f"{n / 1_000:,.1f}K"
    return f"{n:,.1f}"


def fmt_value(n: float, unit: str) -> str:
    if unit == "seconds":
        if n >= 60:
            mins, secs = divmod(n, 60)
            if mins >= 60:
                hours, mins = divmod(mins, 60)
                return f"{int(hours)}h {int(mins)}m"
            return f"{int(mins)}m {secs:.0f}s"
        return f"{n:.2f}s"
    return fmt_num(n)


def fmt_delta(a: float, b: float) -> str:
    if b == 0:
        return "—"
    pct = (a - b) / b * 100
    sign = "+" if pct > 0 else ""
    return f"{sign}{pct:.1f}%"


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def find_runs(results_dir: Path) -> list[dict]:
    runs = []
    for p in sorted(results_dir.glob("*/run.json")):
        try:
            data = json.loads(p.read_text())
            data["_source"] = str(p)
            data["_dir"] = p.parent.name
            runs.append(data)
        except (json.JSONDecodeError, KeyError):
            print(f"  skip (invalid): {p}", file=sys.stderr)
    return runs


def collect_run_json(paths: list[Path]) -> list[dict]:
    runs = []
    for path in paths:
        try:
            data = json.loads(path.read_text())
            data["_source"] = str(path)
            data["_dir"] = path.parent.name
            runs.append(data)
        except (json.JSONDecodeError, KeyError) as exc:
            print(f"  skip (invalid): {path}: {exc}", file=sys.stderr)
    return runs


def make_run_label(run: dict, index: int) -> str:
    ts = run["runtime"]["started"]
    time_part = ts[11:16] if len(ts) >= 16 else ts[:10]
    return f"Run {index + 1} ({time_part} UTC)"


def extract_stats(run: dict, label: str, color: str) -> list[dict]:
    rows = []
    for result in run["results"]:
        test_id = result["id"]
        if not get_extractor(test_id) and not test_id.startswith(("compile.", "runtime.")):
            continue
        raw_values = [metric_value(result, it) for it in result["iterations"]]
        values = [v for v in raw_values if v is not None]
        failed = len(raw_values) - len(values)
        if not values:
            print(
                f"  skip (no valid metric): {label} {test_id}",
                file=sys.stderr,
            )
            continue
        med = statistics.median(values)
        mn, mx = min(values), max(values)
        sd = statistics.stdev(values) if len(values) > 1 else 0.0
        cv = (sd / med * 100) if med else 0.0
        name, unit, higher_better = get_meta(test_id)
        rows.append({
            "label": label,
            "color": color,
            "test_id": test_id,
            "test_name": name,
            "unit": unit,
            "higher_better": higher_better,
            "n": len(values),
            "failed": failed,
            "median": med,
            "min": mn,
            "max": mx,
            "stddev": sd,
            "cv_pct": cv,
        })
    return rows


# ---------------------------------------------------------------------------
# HTML
# ---------------------------------------------------------------------------

def cv_cls(cv: float) -> str:
    if cv > 10:
        return "cv-bad"
    if cv > 5:
        return "cv-warn"
    return ""


def build_html(all_stats: list[dict], runs: list[dict], run_labels: list[str]) -> str:
    # --- Host info cards (deduplicated) ---
    host_blocks = []
    seen_hosts = set()
    for run in runs:
        h = run["host"]
        key = h["hostname"]
        if key in seen_hosts:
            continue
        seen_hosts.add(key)
        host_blocks.append(
            '<div class="host-card">'
            '<dl class="host-grid">'
            f'<div><dt>Hostname</dt><dd>{html.escape(str(h["hostname"]))}</dd></div>'
            f'<div><dt>CPU</dt><dd>{html.escape(str(h["cpu"]["model"]))} ({h["cpu"]["cores_total"]}c'
            f' — {h["cpu"].get("cores_performance", "?")}P + {h["cpu"].get("cores_efficiency", "?")}E)</dd></div>'
            f'<div><dt>RAM</dt><dd>{h["ram_gb"]:.0f} GB</dd></div>'
            f'<div><dt>Storage</dt><dd>{html.escape(str(h["storage"]["model"]))} ({html.escape(str(h["storage"]["filesystem"]))})</dd></div>'
            f'<div><dt>OS</dt><dd>{html.escape(str(h["os"]["name"]))} {html.escape(str(h["os"]["version"]))} / {html.escape(str(h["os"]["arch"]))}</dd></div>'
            '</dl></div>'
        )

    # --- Run conditions table ---
    run_cond_rows = []
    for i, run in enumerate(runs):
        rt = run["runtime"]
        label = run_labels[i]
        color = RUN_COLORS[i % len(RUN_COLORS)]
        started = rt.get("started", "?")[:19].replace("T", " ")
        ended = rt.get("ended", "?")[:19].replace("T", " ")
        power = rt.get("power_source", "?")
        ambient = rt.get("ambient_cpu_pct")
        ambient_s = f"{ambient:.1f}%" if ambient is not None else "—"
        ram_used = rt.get("ambient_ram_used_gb")
        ram_s = f"{ram_used:.1f} GB" if ram_used is not None else "—"
        run_cond_rows.append(
            f'<tr>'
            f'<td><span class="color-dot" style="background:{color}"></span> {label}</td>'
            f'<td>{started}</td><td>{ended}</td>'
            f'<td>{power}</td><td>{ambient_s}</td><td>{ram_s}</td>'
            f'<td>{run["_dir"]}</td>'
            f'</tr>'
        )

    # --- Group stats by test_id (preserving insertion order) ---
    workload_order = []
    by_test: dict[str, list[dict]] = {}
    for s in all_stats:
        if s["test_id"] not in by_test:
            workload_order.append(s["test_id"])
        by_test.setdefault(s["test_id"], []).append(s)

    # --- Benchmark cards ---
    cards = []
    for test_id in workload_order:
        stats = by_test[test_id]
        max_val = max(s["max"] for s in stats)
        scale_val = max(s["max"] for s in stats) if stats[0]["higher_better"] else max(s["median"] for s in stats)
        if scale_val <= 0:
            scale_val = max_val
        name = stats[0]["test_name"]
        unit = stats[0]["unit"]
        hb = stats[0]["higher_better"]
        direction = "higher is better" if hb else "lower is better"

        bars_html = []
        for s in stats:
            pct = (s["median"] / scale_val * 100) if scale_val else 0
            min_pct = (s["min"] / scale_val * 100) if scale_val else 0
            range_w = ((s["max"] - s["min"]) / scale_val * 100) if scale_val else 0
            cv_c = cv_cls(s["cv_pct"])
            cv_tag = f' <span class="bar-cv {cv_c}">CV {s["cv_pct"]:.1f}%</span>' if s["cv_pct"] > 3 else ""
            fail_tag = f' <span class="bar-failed">failed {s["failed"]}</span>' if s["failed"] else ""
            bars_html.append(
                f'<div class="bar-row">'
                f'  <span class="bar-label">'
                f'    <span class="color-dot" style="background:{s["color"]}"></span>{html.escape(s["label"])}'
                f'  </span>'
                f'  <div class="bar-track">'
                f'    <div class="bar-fill" style="width:{pct:.1f}%;background:{s["color"]}">'
                f'      <span class="bar-value">{fmt_value(s["median"], unit)}</span>'
                f'    </div>'
                f'    <div class="bar-range" style="left:{min_pct:.1f}%;width:{range_w:.1f}%"></div>'
                f'  </div>'
                f'  <span class="bar-meta">n={s["n"]}{cv_tag}{fail_tag}</span>'
                f'</div>'
            )

        # Delta between first two runs
        delta_html = ""
        if len(stats) == 2:
            a, b = stats[1]["median"], stats[0]["median"]
            pct_diff = (a - b) / b * 100 if b else 0
            if abs(pct_diff) < 2:
                delta_cls = "delta-neutral"
                verdict = "within noise"
            elif (pct_diff > 0) == hb:
                delta_cls = "delta-good"
                verdict = "better" if hb else "worse"
            else:
                delta_cls = "delta-bad"
                verdict = "worse" if hb else "better"
            sign = "+" if pct_diff > 0 else ""
            delta_html = (
                f'<div class="delta-badge {delta_cls}">'
                f'{sign}{pct_diff:.1f}% — {verdict}'
                f'</div>'
            )

        stat_lines = []
        for s in stats:
            cv_c = cv_cls(s["cv_pct"])
            stat_lines.append(
                f'<div class="stat-line">'
                f'  <span class="color-dot" style="background:{s["color"]}"></span>'
                f'  <span>median <strong>{fmt_value(s["median"], unit)}</strong></span>'
                f'  <span class="sep">|</span>'
                f'  <span>range {fmt_value(s["min"], unit)} – {fmt_value(s["max"], unit)}</span>'
                f'  <span class="sep">|</span>'
                f'  <span>stddev {fmt_value(s["stddev"], unit)}</span>'
                f'  <span class="sep">|</span>'
                f'  <span class="{cv_c}">CV {s["cv_pct"]:.1f}%</span>'
                f'</div>'
            )

        cards.append(
            f'<div class="card">'
            f'  <div class="card-header">'
            f'    <div><h2>{html.escape(name)}</h2><span class="unit">{unit} — {direction}</span></div>'
            f'    {delta_html}'
            f'  </div>'
            f'  <div class="bars">{"".join(bars_html)}</div>'
            f'  <div class="stat-block">{"".join(stat_lines)}</div>'
            f'</div>'
        )

    # --- Raw data table ---
    table_rows = []
    for test_id in workload_order:
        for idx, s in enumerate(by_test[test_id]):
            cv_c = cv_cls(s["cv_pct"])
            group_cls = ' class="group-start"' if idx == 0 else ""
            table_rows.append(
                f'<tr{group_cls}>'
                f'<td>{html.escape(s["test_name"])}</td>'
                f'<td><span class="color-dot" style="background:{s["color"]}"></span> {html.escape(s["label"])}</td>'
                f'<td class="num">{fmt_value(s["median"], s["unit"])}</td>'
                f'<td class="num">{fmt_value(s["min"], s["unit"])}</td>'
                f'<td class="num">{fmt_value(s["max"], s["unit"])}</td>'
                f'<td class="num">{fmt_value(s["stddev"], s["unit"])}</td>'
                f'<td class="num {cv_c}">{s["cv_pct"]:.1f}</td>'
                f'<td class="num">{s["n"]}</td>'
                f'<td class="num">{s["failed"]}</td>'
                f'</tr>'
            )

    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    return HTML_TEMPLATE.format(
        generated=generated,
        num_runs=len(runs),
        host_blocks="".join(host_blocks),
        run_cond_rows="".join(run_cond_rows),
        cards_html="".join(cards),
        table_rows="".join(table_rows),
    )


HTML_TEMPLATE = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>devbench report</title>
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

/* --- Run conditions --- */
.section-label {{ font-size: 1.15rem; font-weight: 600; margin: 1.8rem 0 .6rem; }}
.cond-table {{ width: 100%; border-collapse: collapse; font-size: .85rem; margin-bottom: 2rem; }}
.cond-table th {{
  text-align: left; padding: .5rem .8rem; color: var(--fg2); font-weight: 600;
  font-size: .72rem; text-transform: uppercase; letter-spacing: .05em;
  border-bottom: 1px solid var(--border);
}}
.cond-table td {{ padding: .5rem .8rem; border-bottom: 1px solid var(--border); }}

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

/* --- Delta badge --- */
.delta-badge {{
  font-size: .78rem; font-weight: 600; padding: 3px 10px; border-radius: 12px;
  white-space: nowrap; margin-left: 1rem;
}}
.delta-good {{ background: rgba(63,185,80,.15); color: var(--green); }}
.delta-bad {{ background: rgba(248,81,73,.15); color: var(--red); }}
.delta-neutral {{ background: rgba(139,148,158,.12); color: var(--fg2); }}

/* --- Bars --- */
.bars {{ margin-bottom: .8rem; }}
.bar-row {{ display: flex; align-items: center; gap: .6rem; margin-bottom: .5rem; }}
.bar-label {{ min-width: 140px; font-size: .8rem; white-space: nowrap; display: flex; align-items: center; }}
.bar-track {{
  flex: 1; height: 30px; background: var(--track); border-radius: 4px;
  position: relative; overflow: hidden;
}}
.bar-fill {{
  height: 100%; border-radius: 4px; display: flex; align-items: center;
  padding: 0 10px; transition: width .3s ease;
}}
.bar-value {{ font-size: .82rem; font-weight: 700; color: #fff; white-space: nowrap; }}
.bar-range {{
  position: absolute; top: 4px; bottom: 4px;
  background: rgba(255,255,255,.08); border-radius: 2px;
  border-left: 2px solid rgba(255,255,255,.25);
  border-right: 2px solid rgba(255,255,255,.25);
}}
.bar-meta {{ font-size: .75rem; color: var(--fg2); min-width: 90px; text-align: right; }}
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

/* --- Raw data table --- */
.raw-table {{ width: 100%; border-collapse: collapse; font-size: .85rem; margin-top: .5rem; }}
.raw-table th {{
  text-align: left; padding: .55rem .8rem; color: var(--fg2); font-weight: 600;
  font-size: .72rem; text-transform: uppercase; letter-spacing: .05em;
  border-bottom: 2px solid var(--border); position: sticky; top: 0; background: var(--bg);
}}
.raw-table td {{ padding: .5rem .8rem; border-bottom: 1px solid var(--border); }}
.raw-table tr.group-start td {{ border-top: 2px solid var(--border); }}
.raw-table .num {{ text-align: right; font-variant-numeric: tabular-nums; }}

footer {{ margin-top: 3rem; color: #484f58; font-size: .78rem; text-align: center; }}
</style>
</head>
<body>

<h1>devbench report</h1>
<p class="subtitle">Generated {generated} &mdash; {num_runs} run(s)</p>

<!-- Host info -->
{host_blocks}

<!-- Run conditions -->
<h3 class="section-label">Runs</h3>
<table class="cond-table">
<thead><tr>
  <th>Label</th><th>Started</th><th>Ended</th><th>Power</th><th>Ambient CPU</th><th>RAM used</th><th>Folder</th>
</tr></thead>
<tbody>{run_cond_rows}</tbody>
</table>

<!-- How to read -->
<div class="guide">
  <strong>How to read:</strong>
  Bars show the <strong>median</strong> across iterations. The translucent overlay marks the
  <strong>min–max range</strong>. <code>CV</code> (coefficient of variation) flags noisy results:
  <span style="color:#d29922">yellow &gt; 5%</span>,
  <span style="color:#f85149">red &gt; 10%</span> — treat those with suspicion.
  Delta badges compare Run 2 vs Run 1 (±2% = "within noise").
  Tier 1 cards use workload scores where <strong>higher = better</strong>.
  Tier 2/3 cards use wall-clock time where <strong>lower = better</strong>.
</div>

<!-- Benchmark cards -->
<div class="grid">
{cards_html}
</div>

<!-- Raw data -->
<h3 class="section-label" style="margin-top:2.5rem">Raw data</h3>
<table class="raw-table">
<thead><tr>
  <th>Test</th><th>Run</th><th class="num">Median</th><th class="num">Min</th>
  <th class="num">Max</th><th class="num">StdDev</th><th class="num">CV%</th><th class="num">N</th><th class="num">Failed</th>
</tr></thead>
<tbody>{table_rows}</tbody>
</table>

<footer>devbench v0.1 &mdash; results are host-local, not cross-machine normalised</footer>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Generate devbench HTML report")
    parser.add_argument("results_dir", nargs="?", default="results",
                        help="Directory containing run folders, or a single run.json (default: results)")
    parser.add_argument("--out", default="report.html",
                        help="Output HTML file (default: report.html)")
    args = parser.parse_args()

    input_path = Path(args.results_dir)
    if input_path.is_file():
        runs = collect_run_json([input_path])
    elif input_path.is_dir():
        runs = find_runs(input_path)
    else:
        print(f"Error: {input_path} is not a file or directory", file=sys.stderr)
        sys.exit(1)

    if not runs:
        print(f"No run.json files found under {input_path}", file=sys.stderr)
        sys.exit(1)

    print(f"Loaded {len(runs)} run(s):", file=sys.stderr)
    for r in runs:
        print(f"  {r['_source']}", file=sys.stderr)

    run_labels = [make_run_label(r, i) for i, r in enumerate(runs)]

    all_stats = []
    for i, run in enumerate(runs):
        color = RUN_COLORS[i % len(RUN_COLORS)]
        all_stats.extend(extract_stats(run, run_labels[i], color))

    html = build_html(all_stats, runs, run_labels)
    out = Path(args.out)
    out.write_text(html)
    print(f"\nReport written to {out.resolve()}", file=sys.stderr)


if __name__ == "__main__":
    main()
