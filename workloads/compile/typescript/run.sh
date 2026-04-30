#!/usr/bin/env bash
# Build the TypeScript compiler itself, and (separately) run the new tsgo type-checker
# against the TypeScript repo as the 10x-faster Go-based compiler benchmark.
#
# Usage:
#   run.sh --variant {tsc_cold|tsc_incremental|tsgo_typecheck}
#          [--src-root DIR] [--tag v6.0.3]
#
# tsc variants use `npm run build` (self-hosted compiler build).
# tsgo_typecheck runs `tsgo --noEmit` over the TypeScript repo; tests the new Go
# compiler's throughput on a large real codebase.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$HERE/../../../scripts/common"
CLIB="$HERE/../_lib.sh"
# shellcheck source=../../../scripts/common/lib.sh
source "$COMMON/lib.sh"
# shellcheck source=../_lib.sh
source "$CLIB"

require_cmd git
require_cmd node
require_cmd npm
require_cmd jq

variant="tsc_cold"
src_root="$HERE/../../_src"
tag="v6.0.3"
url="https://github.com/microsoft/TypeScript.git"
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
path="$(ensure_source typescript "$url" "$tag" "$src_root")"

ensure_npm_ci() {
  if [[ ! -d "$path/node_modules" ]]; then
    log_info "npm ci (first time)"
    ( cd "$path" && npm ci --silent --no-audit --no-fund )
  fi
}

case "$variant" in
  tsc_cold)
    ensure_npm_ci
    log_info "clean built/ and built-local/"
    rm -rf "$path/built" "$path/built-local"
    cmd=(npm run build --silent)
    ;;
  tsc_incremental)
    ensure_npm_ci
    log_info "pre-build + touch (incremental setup)"
    ( cd "$path" && npm run build --silent >/tmp/devbench-tsc-inc-prep.log 2>&1 )
    f="$(incremental_file_for typescript)"
    [[ -f "$path/$f" ]] || die "incremental file missing: $path/$f"
    touch "$path/$f"
    cmd=(npm run build --silent)
    ;;
  tsgo_typecheck)
    ensure_npm_ci
    # tsgo is distributed via @typescript/native-preview. Install globally into
    # a local bin dir if the bin isn't already on PATH.
    if ! command -v tsgo >/dev/null 2>&1; then
      log_info "installing @typescript/native-preview (tsgo) locally"
      ( cd "$path" && npm install --silent --no-save --no-audit --no-fund @typescript/native-preview@beta )
      export PATH="$path/node_modules/.bin:$PATH"
    fi
    cmd=(tsgo --noEmit -p "$path/src/tsconfig-base.json")
    ;;
  *) die "unknown variant: $variant" ;;
esac

log_info "build: variant=$variant tag=$tag"
iter_json="$("$COMMON/time_run.sh" \
  --id "compile.typescript.$variant" \
  --cwd "$path" \
  -- "${cmd[@]}")"

node_version="$(node -v 2>/dev/null)"
jq \
  --arg variant "$variant" \
  --arg tag "$tag" \
  --arg tool "$( [[ "$variant" == "tsgo_typecheck" ]] && echo tsgo || echo tsc )" \
  --arg node_version "$node_version" \
  '. + {
    extra: {
      tool: $tool,
      project: "typescript",
      tag: $tag,
      variant: $variant,
      node_version: $node_version
    }
  }' <<<"$iter_json"
