#!/usr/bin/env bash
# Run Vite's own unit test suite (pnpm + vitest). Real-world Node/V8 workload.
#
# Usage:
#   run.sh [--src-root DIR] [--tag v6.0.0]
#
# Single variant only — Vitest runs in parallel by default. We pin `--reporter=basic`
# to avoid spinner/animation overhead which pollutes timings. The first call does
# pnpm install (not timed); subsequent iterations reuse node_modules.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$HERE/../../../scripts/common"
CLIB="$HERE/../../compile/_lib.sh"
# shellcheck source=../../../scripts/common/lib.sh
source "$COMMON/lib.sh"
# shellcheck source=../../compile/_lib.sh
source "$CLIB"

require_cmd git
require_cmd jq
require_cmd node
require_cmd pnpm

src_root="$HERE/../../_src"
tag="v6.0.0"
url="https://github.com/vitejs/vite.git"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src-root) src_root="$2"; shift 2 ;;
    --tag)      tag="$2";      shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

src_root="$(cd "$(dirname "$src_root")" && pwd)/$(basename "$src_root")"
mkdir -p "$src_root"
path="$(ensure_source vite "$url" "$tag" "$src_root")"

if [[ ! -d "$path/node_modules" ]]; then
  log_info "pnpm install (first time; not timed)"
  ( cd "$path" && pnpm install --silent --frozen-lockfile --prefer-offline )
fi

log_info "pnpm test-unit"
iter_json="$("$COMMON/time_run.sh" \
  --id "runtime.vite_tests.default" \
  --cwd "$path" \
  -- pnpm test-unit --reporter=basic)"

node_version="$(node -v)"
pnpm_version="$(pnpm -v)"
jq \
  --arg tag "$tag" \
  --arg tool "vitest" \
  --arg node_version "$node_version" \
  --arg pnpm_version "$pnpm_version" \
  '. + {
    extra: {
      tool: $tool,
      project: "vitejs/vite",
      tag: $tag,
      variant: "default",
      node_version: $node_version,
      pnpm_version: $pnpm_version
    }
  }' <<<"$iter_json"
