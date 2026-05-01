#!/usr/bin/env bash
# stress-ng CPU prime benchmark.
#
# The directory and workload id are kept as `sysbench_cpu` for continuity with
# existing result JSON files (the legacy guard in scripts/common/report.py
# rejects sysbench iterations with impossible event rates). The implementation
# now drives stress-ng --cpu-method prime instead.
#
# Usage:
#   run.sh --threads N [--time-seconds 10] [--max-prime 20000]
#
# Emits a single iteration JSON object to stdout; logs to stderr.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$HERE/../../../scripts/common"
# shellcheck source=../../../scripts/common/lib.sh
source "$COMMON/lib.sh"
require_cmd stress-ng
require_cmd jq

threads=1
time_s=10
max_prime=20000
while [[ $# -gt 0 ]]; do
  case "$1" in
    --threads)       threads="$2";   shift 2 ;;
    --time-seconds)  time_s="$2";    shift 2 ;;
    --max-prime)     max_prime="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

log_info "stress-ng cpu: threads=$threads time=${time_s}s method=prime"

out="$(stress-ng \
  --cpu "$threads" \
  --cpu-method prime \
  --metrics-brief \
  --timeout "${time_s}s" 2>&1)"

# stress-ng output keys of interest:
#   stress-ng: metrc: [...] cpu 16286 3.00 2.98 0.01 5426.35 5437.71
# Columns after "cpu": bogo_ops, real_s, user_s, sys_s, bogo_ops_s_real, bogo_ops_s_cpu.
metrics_line="$(awk '/metrc:/ && $0 ~ /[[:space:]]cpu[[:space:]]/ { line=$0 } END { print line }' <<<"$out")"
read -r total_events wall_s user_s sys_s events_per_s events_per_cpu_s < <(
  awk '
    /metrc:/ && $0 ~ /[[:space:]]cpu[[:space:]]/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "cpu") {
          print $(i+1), $(i+2), $(i+3), $(i+4), $(i+5), $(i+6)
          exit
        }
      }
    }
  ' <<<"$out"
)

[[ -n "${events_per_s:-}" && -n "${wall_s:-}" ]] || {
  log_err "failed to parse stress-ng output:"
  log_err "$out"
  exit 2
}

extra="$(jq -n \
  --argjson threads "$threads" \
  --argjson time_s "$time_s" \
  --argjson max_prime "$max_prime" \
  --arg events_per_s "$events_per_s" \
  --arg events_per_cpu_s "${events_per_cpu_s:-}" \
  --arg total_events "$total_events" \
  --arg metrics_line "$metrics_line" \
  '{
    tool: "stress-ng-cpu",
    threads: $threads,
    configured_time_s: $time_s,
    max_prime: $max_prime,
    cpu_method: "prime",
    events_per_sec: ($events_per_s|tonumber),
    events_per_cpu_sec: (if $events_per_cpu_s == "" then null else ($events_per_cpu_s|tonumber) end),
    bogo_ops_per_sec: ($events_per_s|tonumber),
    raw_metrics_line: $metrics_line,
    total_events: ($total_events|tonumber)
  }')"

emit_iteration --wallclock "$wall_s" --user "$user_s" --sys "$sys_s" --extra "$extra"
