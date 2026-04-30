#!/usr/bin/env bash
# devbench long-task timer.
#
# Wraps a long-running command (think compile jobs) with /usr/bin/time-style
# resource accounting and emits a JSON object that's shape-compatible with
# hyperfine's `.results[N].iterations[M]` entries, so the aggregator can treat
# long and short workloads uniformly.
#
# Intentionally single-iteration — callers loop in the orchestrator to avoid
# double-nesting timing logic.
#
# Usage:
#   time_run.sh --id compile.llvm.cold.jN [--cwd DIR] -- <cmd> [args...]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
require_cmd jq

id=""
cwd=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)  id="$2";  shift 2 ;;
    --cwd) cwd="$2"; shift 2 ;;
    --)    shift; break ;;
    *) die "unknown arg: $1" ;;
  esac
done
[[ -n "$id" ]] || die "--id is required"
[[ $# -gt 0 ]] || die "no command given (use -- <cmd>)"

os="$(detect_os)"

# Locate GNU time if available (gives richer stats); otherwise fall back to shell `time`.
# macOS: /usr/bin/time has BSD semantics; GNU time is `gtime` if installed via coreutils.
gnu_time=""
case "$os" in
  macos)
    if command -v gtime >/dev/null 2>&1; then gnu_time="$(command -v gtime)"
    elif command -v /opt/homebrew/opt/gnu-time/bin/gtime >/dev/null 2>&1; then
      gnu_time="/opt/homebrew/opt/gnu-time/bin/gtime"
    fi
    ;;
  linux|wsl)
    if [[ -x /usr/bin/time ]]; then gnu_time="/usr/bin/time"
    elif command -v gtime >/dev/null 2>&1; then gnu_time="$(command -v gtime)"
    fi
    ;;
esac

tmpstats="$(mktemp)"
trap 'rm -f "$tmpstats"' EXIT

exit_code=0
wall_start_ns="$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')"

if [[ -n "$gnu_time" ]]; then
  # GNU time format: wall(seconds) user(s) sys(s) maxrss(kB) exit
  # -f "%e %U %S %M %x"
  if [[ -n "$cwd" ]]; then pushd "$cwd" >/dev/null; fi
  "$gnu_time" -o "$tmpstats" -f '%e %U %S %M %x' "$@" || exit_code=$?
  if [[ -n "$cwd" ]]; then popd >/dev/null; fi
  read -r wall_s user_s sys_s maxrss_kb gnu_exit < "$tmpstats" || true
  # GNU time sometimes stores its own exit sentinel; fall back to our captured exit_code.
  [[ -z "${gnu_exit:-}" ]] || exit_code="$gnu_exit"
else
  # Shell builtin `time` path. Less accurate for RSS but portable.
  if [[ -n "$cwd" ]]; then pushd "$cwd" >/dev/null; fi
  { TIMEFORMAT='%R %U %S'; { time "$@"; } 2> "$tmpstats"; } || exit_code=$?
  if [[ -n "$cwd" ]]; then popd >/dev/null; fi
  read -r wall_s user_s sys_s < "$tmpstats" || true
  maxrss_kb=""
fi

wall_end_ns="$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')"
# If GNU time missing, derive wall from our own clock.
if [[ -z "${wall_s:-}" ]]; then
  wall_s="$(awk -v s="$wall_start_ns" -v e="$wall_end_ns" 'BEGIN{printf "%.3f", (e-s)/1e9}')"
fi
peak_rss_mb=""
[[ -n "${maxrss_kb:-}" ]] && peak_rss_mb="$(awk -v k="$maxrss_kb" 'BEGIN{printf "%.2f", k/1024}')"

jq -n \
  --arg id "$id" \
  --argjson exit "$exit_code" \
  --arg wall_s "$wall_s" \
  --arg user_s "${user_s:-}" \
  --arg sys_s "${sys_s:-}" \
  --arg peak_rss_mb "${peak_rss_mb:-}" \
  '{
    id: $id,
    exit_code: $exit,
    wallclock_s: ($wall_s|tonumber),
    user_s: (if $user_s == "" then null else ($user_s|tonumber) end),
    sys_s:  (if $sys_s  == "" then null else ($sys_s |tonumber) end),
    peak_rss_mb: (if $peak_rss_mb == "" then null else ($peak_rss_mb|tonumber) end)
  }'

exit "$exit_code"
