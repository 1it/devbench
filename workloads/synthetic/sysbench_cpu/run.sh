#!/usr/bin/env bash
# sysbench CPU prime benchmark.
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
require_cmd sysbench
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

log_info "sysbench cpu: threads=$threads time=${time_s}s max_prime=$max_prime"

out="$(sysbench cpu \
  --threads="$threads" \
  --time="$time_s" \
  --cpu-max-prime="$max_prime" \
  run 2>&1)"

# sysbench output keys of interest:
#   events per second:   27594.52        (aggregate across threads)
#   total time:          10.0003s
#   total number of events: 275957
events_per_s="$(awk -F: '/events per second/ {gsub(/[ \t]/,"",$2); print $2}' <<<"$out")"
total_events="$(awk -F: '/total number of events/ {gsub(/[ \t]/,"",$2); print $2}' <<<"$out")"
wall_s="$(awk -F: '/total time:/ {gsub(/[ \ts]/,"",$2); print $2}' <<<"$out")"

[[ -n "$events_per_s" && -n "$wall_s" ]] || {
  log_err "failed to parse sysbench output:"
  log_err "$out"
  exit 2
}

extra="$(jq -n \
  --argjson threads "$threads" \
  --argjson time_s "$time_s" \
  --argjson max_prime "$max_prime" \
  --arg events_per_s "$events_per_s" \
  --arg total_events "$total_events" \
  '{
    tool: "sysbench-cpu",
    threads: $threads,
    configured_time_s: $time_s,
    max_prime: $max_prime,
    events_per_sec: ($events_per_s|tonumber),
    total_events: ($total_events|tonumber)
  }')"

emit_iteration --wallclock "$wall_s" --extra "$extra"
