#!/usr/bin/env bash
# devbench self-test / calibration.
# Runs a deterministic workload (sha256 of a fixed in-memory buffer) multiple
# times and verifies the coefficient of variation is below a threshold.
# If it isn't, the machine is noisy and results would be garbage.
#
# Also verifies required tools are present and that the host probe works.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

cv_threshold_pct="${DEVBENCH_CV_THRESHOLD:-3.0}"
iters="${DEVBENCH_CALIB_ITERS:-10}"

require_cmd jq
require_cmd hyperfine
require_cmd openssl

os="$(detect_os)"
log_info "self-test on $os ($(detect_arch))"

# 1. Required tools sanity check (soft: warn, don't fail if missing).
tools=(git jq hyperfine openssl awk)
for t in "${tools[@]}"; do
  if command -v "$t" >/dev/null 2>&1; then
    log_info "$t: $(command -v "$t")"
  else
    log_warn "$t: missing"
  fi
done

# 2. Host probe executes cleanly.
probe=""
case "$os" in
  macos)      probe="$SCRIPT_DIR/../macos/probe.sh" ;;
  linux|wsl)  probe="$SCRIPT_DIR/../linux/probe.sh" ;;
  *) die "no probe for os: $os" ;;
esac
log_info "running host probe: $probe"
probe_json="$("$probe")"
echo "$probe_json" | jq '.hostname, .os.name, .cpu.model' >&2

# 3. Calibration: repeatable CPU-bound task. sha256 on 128 MB of zeros in RAM.
# We do the full pipe in one shot per iteration via `openssl dgst`.
# The workload is identical each run -> any variance is system noise.
log_info "calibration: $iters iterations of sha256(128MB) ..."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
out="$tmp/calib.json"
hyperfine \
  --warmup 2 \
  --min-runs "$iters" \
  --max-runs "$iters" \
  --shell=none \
  --export-json "$out" \
  --command-name "calib_sha256_128M" \
  "bash -c 'head -c 134217728 /dev/zero | openssl dgst -sha256 >/dev/null'" \
  >/dev/null

mean="$(jq -r '.results[0].mean'   "$out")"
stddev="$(jq -r '.results[0].stddev' "$out")"
cv_pct="$(awk -v m="$mean" -v s="$stddev" 'BEGIN{ if (m>0) printf "%.3f", (s/m)*100; else print "NaN" }')"
log_info "mean=${mean}s stddev=${stddev}s cv=${cv_pct}%"

verdict="ok"
if awk -v c="$cv_pct" -v t="$cv_threshold_pct" 'BEGIN{ exit !(c > t) }'; then
  verdict="noisy"
fi

jq -n \
  --arg verdict "$verdict" \
  --arg os "$os" \
  --arg arch "$(detect_arch)" \
  --argjson mean "$mean" \
  --argjson stddev "$stddev" \
  --argjson cv_pct "$cv_pct" \
  --argjson threshold "$cv_threshold_pct" \
  --argjson iters "$iters" \
  '{
    verdict: $verdict,
    os: $os,
    arch: $arch,
    calib: {
      workload: "sha256_128M",
      iterations: $iters,
      mean_s: $mean,
      stddev_s: $stddev,
      cv_pct: $cv_pct,
      threshold_pct: $threshold
    }
  }'

if [[ "$verdict" == "noisy" ]]; then
  log_err "CV ${cv_pct}% exceeds threshold ${cv_threshold_pct}%. Machine is noisy — re-run preflight (docs/preflight.md)."
  exit 2
fi
log_info "self-test passed."
