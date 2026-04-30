#!/usr/bin/env bash
# Run a scoped subset of pandas' pytest suite.
#
# Usage:
#   run.sh --variant {parallel|serial} [--src-root DIR] [--tag v3.0.2]
#          [--subset "pandas/tests/frame pandas/tests/series"]
#
# Runs the subset twice: once with -n auto (if pytest-xdist available), once with -n 1
# for ST measurement. We report one iteration per invocation; orchestrator invokes twice.
#
# Setup is idempotent: re-uses an existing virtualenv under $src/.devbench-venv if valid.

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

variant="parallel"
src_root="$HERE/../../_src"
tag="v3.0.2"
subset="pandas/tests/frame/methods pandas/tests/series/methods pandas/tests/indexing"
url="https://github.com/pandas-dev/pandas.git"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant)   variant="$2";  shift 2 ;;
    --src-root)  src_root="$2"; shift 2 ;;
    --tag)       tag="$2";      shift 2 ;;
    --subset)    subset="$2";   shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

src_root="$(cd "$(dirname "$src_root")" && pwd)/$(basename "$src_root")"
mkdir -p "$src_root"
path="$(ensure_source pandas "$url" "$tag" "$src_root")"

venv="$path/.devbench-venv"
python_bin=""
for cand in python3.13 python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then python_bin="$(command -v "$cand")"; break; fi
done
[[ -n "$python_bin" ]] || die "python3 not found"

if [[ ! -d "$venv" ]]; then
  log_info "creating venv with uv (or python -m venv fallback)"
  if command -v uv >/dev/null 2>&1; then
    uv venv "$venv" --python "$python_bin" >/dev/null
  else
    "$python_bin" -m venv "$venv"
  fi
fi
# shellcheck source=/dev/null
. "$venv/bin/activate"

# Install pandas + dev deps. Skipping build-from-source: we install pandas from wheel
# matching the tag, plus pytest. Honest benchmark: we're measuring pytest cost on pandas
# tests, not pandas' build time (that's already covered by no compile workload).
log_info "installing pandas == ${tag#v} + test deps"
if command -v uv >/dev/null 2>&1; then
  uv pip install --quiet --python "$venv/bin/python" \
    "pandas==${tag#v}" pytest pytest-xdist hypothesis numpy pyarrow
else
  pip install --quiet --disable-pip-version-check "pandas==${tag#v}" pytest pytest-xdist hypothesis numpy pyarrow
fi

# pandas' own test suite is shipped inside the installed package for v3.x. Run pytest
# against the installed pandas, not the source tree (which wouldn't be built).
installed_tests="$(python -c 'import pandas, os; print(os.path.join(os.path.dirname(pandas.__file__), "tests"))')"
log_info "tests dir: $installed_tests"

# Translate subset paths (which are relative to the repo) to paths under the installed tree.
mapped=()
for part in $subset; do
  part_tail="${part#pandas/tests/}"
  mapped+=("$installed_tests/$part_tail")
done

pytest_args=(-p no:cacheprovider --no-header -q)
case "$variant" in
  parallel) pytest_args+=(-n auto) ;;
  serial)   pytest_args+=(-n 1) ;;
  *) die "unknown variant: $variant" ;;
esac

log_info "pytest variant=$variant: ${mapped[*]}"
iter_json="$("$COMMON/time_run.sh" \
  --id "runtime.pytest_pandas.$variant" \
  -- python -m pytest "${pytest_args[@]}" "${mapped[@]}")"

py_version="$(python --version 2>&1 | awk '{print $2}')"
pd_version="$(python -c 'import pandas; print(pandas.__version__)' 2>/dev/null || echo "$tag")"

jq \
  --arg variant "$variant" \
  --arg tag "$tag" \
  --arg subset "$subset" \
  --arg tool "pytest" \
  --arg py_version "$py_version" \
  --arg pd_version "$pd_version" \
  '. + {
    extra: {
      tool: $tool,
      project: "pandas",
      tag: $tag,
      variant: $variant,
      subset: $subset,
      python_version: $py_version,
      pandas_version: $pd_version
    }
  }' <<<"$iter_json"
