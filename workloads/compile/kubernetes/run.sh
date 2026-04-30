#!/usr/bin/env bash
# Build kubernetes/ with `go build ./...`.
#
# Usage:
#   run.sh --variant {cold|warm} [--src-root DIR] [--tag v1.35.3]
#
# Variants:
#   cold : GOCACHE disabled, fresh build
#   warm : GOCACHE enabled (default), second build after cold

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$HERE/../../../scripts/common"
CLIB="$HERE/../_lib.sh"
# shellcheck source=../../../scripts/common/lib.sh
source "$COMMON/lib.sh"
# shellcheck source=../_lib.sh
source "$CLIB"

require_cmd git
require_cmd go
require_cmd jq

variant="cold"
src_root="$HERE/../../_src"
tag="v1.35.3"
url="https://github.com/kubernetes/kubernetes.git"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant)  variant="$2";  shift 2 ;;
    --src-root) src_root="$2"; shift 2 ;;
    --tag)      tag="$2";      shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

src_root="$(cd "$(dirname "$src_root")" && pwd)/$(basename "$src_root")"
mkdir -p "$src_root"
path="$(ensure_source kubernetes "$url" "$tag" "$src_root")"

# GOCACHE: cold runs go to a scratch dir that we nuke; warm runs use default.
case "$variant" in
  cold)
    export GOCACHE="$path/.gocache-cold"
    rm -rf "$GOCACHE"
    mkdir -p "$GOCACHE"
    ;;
  warm)
    # Prime first so the warm timing is a real re-build with cached deps.
    log_info "pre-build (warm setup, using default GOCACHE)"
    ( cd "$path" && go build ./... >/tmp/devbench-k8s-warm-prep.log 2>&1 || true )
    ;;
  *) die "unknown variant: $variant" ;;
esac

log_info "build: variant=$variant tag=$tag"
iter_json="$("$COMMON/time_run.sh" \
  --id "compile.kubernetes.$variant" \
  --cwd "$path" \
  -- go build ./...)"

go_version="$(go version 2>/dev/null | awk '{print $3}')"
jq \
  --arg variant "$variant" \
  --arg tag "$tag" \
  --arg tool "go build" \
  --arg go_version "$go_version" \
  --arg gocache "${GOCACHE:-default}" \
  '. + {
    extra: {
      tool: $tool,
      project: "kubernetes",
      tag: $tag,
      variant: $variant,
      go_version: $go_version,
      gocache: $gocache
    }
  }' <<<"$iter_json"
