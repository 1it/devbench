#!/usr/bin/env bash
# devbench top-level orchestrator (macOS / Linux / WSL).
#
# Usage:
#   scripts/run.sh [--tier 1[,2,3]] [--iterations N] [--scratch DIR]
#                  [--output DIR] [--skip-self-test] [--ambient-seconds S]
#                  [--no-report] [--no-open-report] [--report-scope current|all]
#
# Produces run.json and report.html under results/<hostname>-<YYYYMMDD-HHMMSS>/.
#
# NOTE: Windows has its own scripts/run.ps1 (not yet written; M5).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./common/lib.sh
source "$SCRIPT_DIR/common/lib.sh"
require_cmd jq

tiers="1"
iterations=3
scratch="${REPO_ROOT}/workloads/_scratch"
output_root="${REPO_ROOT}/results"
run_self_test=1
ambient_s=10
generate_report=1
open_report=1
report_scope="current"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier|--tiers)      tiers="$2";         shift 2 ;;
    --iterations)        iterations="$2";    shift 2 ;;
    --scratch)           scratch="$2";       shift 2 ;;
    --output)            output_root="$2";   shift 2 ;;
    --skip-self-test)    run_self_test=0;    shift ;;
    --ambient-seconds)   ambient_s="$2";     shift 2 ;;
    --no-report)         generate_report=0;  open_report=0; shift ;;
    --no-open-report)    open_report=0;      shift ;;
    --report-scope)      report_scope="$2";  shift 2 ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown arg: $1" ;;
  esac
done

os="$(detect_os)"
case "$os" in
  macos|linux|wsl) : ;;
  *) die "unsupported os: $os (use scripts/run.ps1 on Windows)" ;;
esac

case "$report_scope" in
  current|all) : ;;
  *) die "unknown --report-scope: $report_scope (expected current|all)" ;;
esac

open_html_report() {
  local report_file="$1"
  case "$os" in
    macos)
      command -v open >/dev/null 2>&1 || return 1
      open "$report_file" >/dev/null 2>&1 &
      ;;
    linux)
      [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] || return 1
      command -v xdg-open >/dev/null 2>&1 || return 1
      xdg-open "$report_file" >/dev/null 2>&1 &
      ;;
    wsl)
      if command -v wslview >/dev/null 2>&1; then
        wslview "$report_file" >/dev/null 2>&1 &
      elif command -v explorer.exe >/dev/null 2>&1; then
        explorer.exe "$(wslpath -w "$report_file")" >/dev/null 2>&1 &
      else
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

probe_script="$SCRIPT_DIR/$os/probe.sh"
[[ "$os" == "wsl" ]] && probe_script="$SCRIPT_DIR/linux/probe.sh"
[[ -x "$probe_script" ]] || die "probe script missing or not executable: $probe_script"

mkdir -p "$scratch" "$output_root"
ts="$(date -u +"%Y%m%d-%H%M%S")"
hostname_s="$(hostname -s 2>/dev/null || cat /etc/hostname)"
out_dir="$output_root/${hostname_s}-${ts}"
mkdir -p "$out_dir"
log_info "output dir: $out_dir"

if [[ "$run_self_test" -eq 1 ]]; then
  log_info "running self-test..."
  if ! self_json="$("$SCRIPT_DIR/common/self_test.sh")"; then
    log_err "self-test failed (machine too noisy). Re-run docs/preflight.md, then retry, or pass --skip-self-test to force."
    echo "$self_json" > "$out_dir/self_test.json" || true
    exit 2
  fi
  echo "$self_json" > "$out_dir/self_test.json"
fi

log_info "probing host..."
host_json="$("$probe_script")"

log_info "capturing initial runtime state..."
runtime_json="$("$SCRIPT_DIR/common/runtime_init.sh" --ambient-seconds "$ambient_s" --config "$REPO_ROOT/configs/default.yaml" 2>/dev/null)"

# Build tier-to-workloads-specs map. Hardcoded until we wire YAML parsing (yq dep).
build_tier_specs() {
  local tier="$1"
  case "$tier" in
    1)
      # Tier 1 synthetic. Each line: id|tier|cwd|cmd
      # cwd is empty (run in repo root).
      local nproc
      case "$os" in
        macos)  nproc="$(sysctl -n hw.logicalcpu)" ;;
        linux|wsl) nproc="$(nproc 2>/dev/null || echo 4)" ;;
      esac
      cat <<EOF
synthetic.sysbench_cpu.st|1||$REPO_ROOT/workloads/synthetic/sysbench_cpu/run.sh --threads 1
synthetic.sysbench_cpu.mt|1||$REPO_ROOT/workloads/synthetic/sysbench_cpu/run.sh --threads $nproc
synthetic.sevenzip|1||$REPO_ROOT/workloads/synthetic/sevenzip/run.sh
synthetic.fio.4k_qd1|1||$REPO_ROOT/workloads/synthetic/fio/run.sh --profile 4k_qd1 --scratch-dir $scratch --size 1G --runtime 15
synthetic.fio.seq|1||$REPO_ROOT/workloads/synthetic/fio/run.sh --profile seq --scratch-dir $scratch --size 2G --runtime 15
synthetic.fio.mixed|1||$REPO_ROOT/workloads/synthetic/fio/run.sh --profile mixed --scratch-dir $scratch --size 2G --runtime 15
EOF
      ;;
    2)
      # Compile tier. These take minutes to tens of minutes; default iterations
      # in the orchestrator should be tuned lower (2) when --tier 2 is active.
      cat <<EOF
compile.ripgrep.cold|2||$REPO_ROOT/workloads/compile/ripgrep/run.sh --variant cold
compile.ripgrep.warm|2||$REPO_ROOT/workloads/compile/ripgrep/run.sh --variant warm
compile.ripgrep.incremental|2||$REPO_ROOT/workloads/compile/ripgrep/run.sh --variant incremental
compile.typescript.tsc_cold|2||$REPO_ROOT/workloads/compile/typescript/run.sh --variant tsc_cold
compile.typescript.tsc_incremental|2||$REPO_ROOT/workloads/compile/typescript/run.sh --variant tsc_incremental
compile.typescript.tsgo_typecheck|2||$REPO_ROOT/workloads/compile/typescript/run.sh --variant tsgo_typecheck
compile.kubernetes.cold|2||$REPO_ROOT/workloads/compile/kubernetes/run.sh --variant cold
compile.kubernetes.warm|2||$REPO_ROOT/workloads/compile/kubernetes/run.sh --variant warm
compile.llvm.cold_jN|2||$REPO_ROOT/workloads/compile/llvm/run.sh --variant cold_jN
compile.llvm.cold_j1|2||$REPO_ROOT/workloads/compile/llvm/run.sh --variant cold_j1
compile.llvm.warm_jN|2||$REPO_ROOT/workloads/compile/llvm/run.sh --variant warm_jN
compile.llvm.incremental|2||$REPO_ROOT/workloads/compile/llvm/run.sh --variant incremental
compile.duckdb.cold|2||$REPO_ROOT/workloads/compile/duckdb/run.sh --variant cold
EOF
      # Linux-only extras
      if [[ "$os" == "linux" || "$os" == "wsl" ]]; then
        cat <<EOF
compile.linux_kernel.cold_jN|2||$REPO_ROOT/workloads/compile/linux_kernel/run.sh --variant cold_jN
compile.linux_kernel.incremental|2||$REPO_ROOT/workloads/compile/linux_kernel/run.sh --variant incremental
compile.ripgrep.cold_mold|2||$REPO_ROOT/workloads/compile/ripgrep/run.sh --variant cold_mold
EOF
      fi
      ;;
    3)
      # Tier 3 runtime / test execution. Each workload is minutes-long, not hours.
      cat <<EOF
runtime.pytest_pandas.parallel|3||$REPO_ROOT/workloads/runtime/pytest_pandas/run.sh --variant parallel
runtime.pytest_pandas.serial|3||$REPO_ROOT/workloads/runtime/pytest_pandas/run.sh --variant serial
runtime.vite_tests|3||$REPO_ROOT/workloads/runtime/vite_tests/run.sh
runtime.renaissance|3||$REPO_ROOT/workloads/runtime/renaissance/run.sh
runtime.docker_build_rust.cold|3||$REPO_ROOT/workloads/runtime/docker_build_rust/run.sh --variant cold
runtime.docker_build_rust.warm|3||$REPO_ROOT/workloads/runtime/docker_build_rust/run.sh --variant warm
EOF
      ;;
    4|5|6|7)
      log_warn "tier $tier specs not yet implemented (coming in M7+)"
      ;;
    *) die "unknown tier: $tier" ;;
  esac
}

# Collect specs for the requested tiers.
specs_tmp="$(mktemp)"
trap 'rm -f "$specs_tmp"' EXIT
IFS=',' read -ra tier_list <<<"$tiers"
for t in "${tier_list[@]}"; do
  build_tier_specs "$t" >> "$specs_tmp"
done

if [[ ! -s "$specs_tmp" ]]; then
  die "no workloads selected (check --tier argument)"
fi

log_info "running workloads..."
results_json="$("$SCRIPT_DIR/common/run_tier.sh" --iterations "$iterations" < "$specs_tmp")"

ended_ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
# Merge ended into runtime.
runtime_json="$(jq --arg ended "$ended_ts" '. + {ended: $ended}' <<<"$runtime_json")"

final_json="$(jq -n \
  --arg schema "1" \
  --argjson host "$host_json" \
  --argjson runtime "$runtime_json" \
  --argjson results "$results_json" \
  '{
    schema_version: $schema,
    host: $host,
    runtime: $runtime,
    results: $results
  }')"

out_file="$out_dir/run.json"
echo "$final_json" > "$out_file"
log_info "wrote $out_file"

if [[ "$generate_report" -eq 1 ]]; then
  report_script="$SCRIPT_DIR/common/report.py"
  if [[ -f "$report_script" ]] && command -v python3 >/dev/null 2>&1; then
    case "$report_scope" in
      current)
        report_input="$out_file"
        report_file="$out_dir/report.html"
        ;;
      all)
        report_input="$output_root"
        report_file="$output_root/report.html"
        ;;
    esac

    log_info "generating report: $report_file"
    if python3 "$report_script" "$report_input" --out "$report_file" >/tmp/devbench-report.log 2>&1; then
      log_info "wrote $report_file"
      if [[ "$open_report" -eq 1 ]]; then
        if open_html_report "$report_file"; then
          log_info "opened $report_file"
        else
          log_warn "could not open report automatically; open manually: $report_file"
        fi
      fi
    else
      log_warn "report generation failed; see /tmp/devbench-report.log"
    fi
  else
    log_warn "skipped report generation (missing python3 or $report_script)"
  fi
fi

echo "$out_file"
