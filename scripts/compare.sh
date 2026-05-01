#!/usr/bin/env bash
# Generate aggregate comparison reports across devbench runs.
#
# Usage:
#   scripts/compare.sh [results_dir] [--baseline path/to/run.json]
#                      [--profile current|headline] [--out-dir DIR]
#                      [--run-selection latest|aggregate|session]
#                      [--open|--no-open]
#
# Outputs:
#   results/aggregate/scores.json
#   results/aggregate/summary.csv
#   results/aggregate/comparison.md
#   results/aggregate/comparison.html

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./common/lib.sh
source "$SCRIPT_DIR/common/lib.sh"

results_input="$REPO_ROOT/results"
baseline=""
profile="current"
run_selection="latest"
out_dir="$REPO_ROOT/results/aggregate"
open_report=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline) baseline="$2"; shift 2 ;;
    --profile)  profile="$2";  shift 2 ;;
    --run-selection) run_selection="$2"; shift 2 ;;
    --out-dir)  out_dir="$2";  shift 2 ;;
    --open)     open_report=1; shift ;;
    --no-open)  open_report=0; shift ;;
    -h|--help)
      awk '
        /^# shellcheck/ { next }
        /^#( |$)/ { sub(/^# ?/, ""); print; next }
        NR > 1 { exit }
      ' "$0"
      exit 0
      ;;
    --*) die "unknown arg: $1" ;;
    *)
      results_input="$1"
      shift
      ;;
  esac
done

require_cmd python3

open_html_report() {
  local report_file="$1"
  case "$(detect_os)" in
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

cmd=(
  python3 "$SCRIPT_DIR/common/aggregate.py" "$results_input"
  --profile "$profile"
  --run-selection "$run_selection"
  --out-dir "$out_dir"
)
if [[ -n "$baseline" ]]; then
  cmd+=(--baseline "$baseline")
fi

log_info "generating aggregate comparison..."
"${cmd[@]}"

report_file="$out_dir/comparison.html"
if [[ "$open_report" -eq 1 ]]; then
  if open_html_report "$report_file"; then
    log_info "opened $report_file"
  else
    log_warn "could not open report automatically; open manually: $report_file"
  fi
fi

echo "$report_file"
