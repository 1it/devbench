#!/usr/bin/env bash
# Build DuckDB. Heavy C++ template workload.
#
# Usage:
#   run.sh --variant {cold} [--src-root DIR] [--tag v1.5.2]
#
# NOTE: M4.1 — structure complete, but the actual heavy-template compile path
# may need `make release` or `cmake --build build --target duckdb`; confirm on
# first real run and adjust. Currently uses the upstream Makefile `release`
# target which is what the DuckDB CI uses.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$HERE/../../../scripts/common"
CLIB="$HERE/../_lib.sh"
# shellcheck source=../../../scripts/common/lib.sh
source "$COMMON/lib.sh"
# shellcheck source=../_lib.sh
source "$CLIB"

require_cmd git
require_cmd cmake
require_cmd ninja
require_cmd jq
require_cmd make

variant="cold"
src_root="$HERE/../../_src"
tag="v1.5.2"
url="https://github.com/duckdb/duckdb.git"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant)  variant="$2";  shift 2 ;;
    --src-root) src_root="$2"; shift 2 ;;
    --tag)      tag="$2";      shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ "$variant" == "cold" ]] || die "duckdb: only cold variant implemented in M4"

src_root="$(cd "$(dirname "$src_root")" && pwd)/$(basename "$src_root")"
mkdir -p "$src_root"
path="$(ensure_source duckdb "$url" "$tag" "$src_root")"

log_info "clean build dir"
rm -rf "$path/build"

jobs="$(default_jobs)"
log_info "build: variant=$variant jobs=$jobs tag=$tag"
# DuckDB's Makefile defaults to Release and sets up cmake + ninja internally.
iter_json="$("$COMMON/time_run.sh" \
  --id "compile.duckdb.$variant" \
  --cwd "$path" \
  -- env GEN=ninja BUILD_JEMALLOC=0 BUILD_SHELL=0 make release -j "$jobs")"

jq \
  --arg variant "$variant" \
  --arg tag "$tag" \
  --argjson jobs "$jobs" \
  --arg tool "make+cmake+ninja" \
  '. + {
    extra: {
      tool: $tool,
      project: "duckdb",
      tag: $tag,
      variant: $variant,
      jobs: $jobs
    }
  }' <<<"$iter_json"
