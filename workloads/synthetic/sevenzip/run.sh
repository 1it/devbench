#!/usr/bin/env bash
# 7-zip built-in benchmark.
#
# Usage:
#   run.sh [--threads N]      # omit to use 7z default (all cores)
#          [--dict-mb 32]     # dictionary size in MB (default 32)
#
# Emits a single iteration JSON object to stdout.
#
# 7z's mean row looks like:
# 23:   Avr:     4821  7236   132212 13424     6123 10142  16336 17378 16836
#       ^time%  ^speed ...
# We parse the two final aggregate lines labelled "Avr" (compression + decompression) and
# the "Tot" line (overall rating in MIPS).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$HERE/../../../scripts/common"
# shellcheck source=../../../scripts/common/lib.sh
source "$COMMON/lib.sh"
require_cmd jq

threads=""
dict_mb=32
while [[ $# -gt 0 ]]; do
  case "$1" in
    --threads) threads="$2"; shift 2 ;;
    --dict-mb) dict_mb="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

# 7z binary name varies: macOS homebrew p7zip => `7z`, debian => `7z` (or `7zz` with newer p7zip fork).
bin=""
for cand in 7zz 7z; do
  if command -v "$cand" >/dev/null 2>&1; then bin="$cand"; break; fi
done
[[ -n "$bin" ]] || die "7z binary not found (install p7zip-full / p7zip)"

thread_flag=""
[[ -n "$threads" ]] && thread_flag="-mmt=$threads"

# -md<N> in 7z 'b' command is log2 dict size in bytes; 32 MB -> md25.
awk_val="$(awk -v v="$dict_mb" 'BEGIN{
  n=0; x=v*1024*1024;
  while (x > 1) { x = x / 2; n++ }
  print n
}')"

log_info "$bin b -md${awk_val} ${thread_flag:-} (dict=${dict_mb}MB, threads=${threads:-default})"

t0="$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')"
out="$("$bin" b -md"$awk_val" $thread_flag 2>&1 || true)"
t1="$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')"
wall_s="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')"

# Parse aggregates. Example lines:
#   Avr:              4873  7334  135252  13738    6132  10171  16323  17391
#   Tot:              4937  8753  132745
# The "Tot:" line's numeric cols differ between 7z versions; safest to grab the mean
# compression/decompression speed (cols 3 and 7 on Avr) and the MIPS rating on Tot (col 3).
avr_line="$(grep -E '^Avr:' <<<"$out" | tail -n1 || true)"
tot_line="$(grep -E '^Tot:' <<<"$out" | tail -n1 || true)"

compress_mips=""
decompress_mips=""
total_mips=""
if [[ -n "$avr_line" ]]; then
  # Cols after "Avr:" => CU CR CompSpeedKBs CompRatingMIPS DU DR DecompSpeedKBs DecompRatingMIPS
  compress_mips="$(awk '{print $5}' <<<"$avr_line")"
  decompress_mips="$(awk '{print $9}' <<<"$avr_line")"
fi
if [[ -n "$tot_line" ]]; then
  total_mips="$(awk '{print $4}' <<<"$tot_line")"
fi

[[ -n "$total_mips" ]] || {
  log_err "failed to parse 7z output:"
  log_err "$out"
  exit 2
}

extra="$(jq -n \
  --arg tool "7z-bench" \
  --arg bin "$bin" \
  --argjson dict_mb "$dict_mb" \
  --arg threads "${threads:-}" \
  --arg cmips "${compress_mips:-}" \
  --arg dmips "${decompress_mips:-}" \
  --arg tmips "$total_mips" \
  '{
    tool: $tool,
    bin: $bin,
    dict_mb: $dict_mb,
    threads: (if $threads == "" then null else ($threads|tonumber) end),
    compress_mips:   (if $cmips == "" then null else ($cmips|tonumber) end),
    decompress_mips: (if $dmips == "" then null else ($dmips|tonumber) end),
    total_mips:      ($tmips|tonumber)
  }')"

emit_iteration --wallclock "$wall_s" --extra "$extra"
