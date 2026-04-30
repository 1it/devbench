#!/usr/bin/env bash
# Run a list of workload invocations N times each and emit the `results` array
# (the top-level orchestrator is responsible for adding host / runtime / schema_version).
#
# This script reads a whitespace-separated list of workload "specs" from stdin; one per line:
#
#   <id>|<tier>|<working_dir>|<cmd...>
#
# Example:
#   synthetic.sysbench_cpu.st|1|/tmp/devbench|workloads/synthetic/sysbench_cpu/run.sh --threads 1
#
# Each spec is executed --iterations times; its stdout (one iteration JSON per run) is
# aggregated into a single results entry.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cmd jq

iterations=3
cold_between=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations)   iterations="$2";    shift 2 ;;
    --no-cold)      cold_between=0;     shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

drop_caches() {
  case "$(detect_os)" in
    macos)
      # `purge` requires sudo without prompt to be useful in automation; skip if we can't.
      if sudo -n purge >/dev/null 2>&1; then log_info "dropped caches (purge)"
      else log_warn "skipped cache drop (sudo -n purge unavailable)"
      fi
      ;;
    linux|wsl)
      if [[ "$(id -u)" == "0" ]]; then sync; echo 3 > /proc/sys/vm/drop_caches; log_info "dropped caches"
      elif sudo -n sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' >/dev/null 2>&1; then log_info "dropped caches (sudo)"
      else log_warn "skipped cache drop (no sudo)"
      fi
      ;;
  esac
}

results=()

while IFS= read -r spec; do
  # Skip blanks and comments.
  [[ -z "$spec" || "$spec" == \#* ]] && continue
  id="${spec%%|*}"; rest="${spec#*|}"
  tier="${rest%%|*}"; rest="${rest#*|}"
  cwd="${rest%%|*}"; cmd="${rest#*|}"

  log_info "=== $id (tier $tier) x $iterations ==="
  iters_json=()
  for ((i=1; i<=iterations; i++)); do
    log_info "  iter $i/$iterations"
    [[ "$cold_between" -eq 1 && $i -gt 1 ]] && drop_caches
    # shellcheck disable=SC2086
    if [[ -n "$cwd" ]]; then pushd "$cwd" >/dev/null; fi
    if iter_json="$(eval "$cmd" 2> >(tee -a /tmp/devbench-$id.log >&2))"; then
      iters_json+=("$iter_json")
    else
      log_err "workload $id iter $i failed"
      iters_json+=("$(jq -n --arg id "$id" '{wallclock_s: null, error: "workload failed"}')")
    fi
    if [[ -n "$cwd" ]]; then popd >/dev/null; fi
  done

  # Combine into one result entry.
  iters_arr="$(printf '%s\n' "${iters_json[@]}" | jq -s '.')"
  entry="$(jq -n \
    --arg id "$id" \
    --argjson tier "$tier" \
    --argjson iters "$iters_arr" \
    '{
      id: $id,
      tier: $tier,
      iterations: $iters
    }')"
  results+=("$entry")
done

printf '%s\n' "${results[@]}" | jq -s '.'
