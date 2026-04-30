#!/usr/bin/env bash
# Run a subset of the Renaissance JVM benchmark suite.
#
# Usage:
#   run.sh [--version 0.16.1] [--cache-dir DIR]
#          [--benchmarks "scala-kmeans fj-kmeans dotty als finagle-http rx-scrabble"]
#          [--repetitions 3]
#
# Uses the renaissance-gpl-<ver>.jar (downloaded once, cached). We deliberately avoid
# the full suite (takes 30+ min); a representative cross-domain subset gives stable
# signal at ~3-5 min per iteration.
#
# Emits one iteration JSON covering the whole subset. Per-benchmark scores are
# captured in extra.per_benchmark from the Renaissance JSON output.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$HERE/../../../scripts/common"
# shellcheck source=../../../scripts/common/lib.sh
source "$COMMON/lib.sh"

require_cmd java
require_cmd jq
require_cmd curl

version="0.16.1"
cache_dir="$HERE/../../_src/renaissance"
benchmarks="scala-kmeans fj-kmeans dotty als finagle-http rx-scrabble"
repetitions=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)      version="$2";     shift 2 ;;
    --cache-dir)    cache_dir="$2";   shift 2 ;;
    --benchmarks)   benchmarks="$2";  shift 2 ;;
    --repetitions)  repetitions="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

mkdir -p "$cache_dir"
jar="$cache_dir/renaissance-gpl-$version.jar"
if [[ ! -f "$jar" ]]; then
  url="https://github.com/renaissance-benchmarks/renaissance/releases/download/v${version}/renaissance-gpl-${version}.jar"
  log_info "downloading $url"
  curl -fL --retry 3 --retry-delay 2 -o "$jar.partial" "$url"
  mv "$jar.partial" "$jar"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
result_json="$tmp/result.json"

# shellcheck disable=SC2086
log_info "running renaissance: benchmarks=[$benchmarks] repetitions=$repetitions"
iter_json="$("$COMMON/time_run.sh" \
  --id "runtime.renaissance.subset" \
  -- java -jar "$jar" \
      --json "$result_json" \
      --repetitions "$repetitions" \
      --no-forced-gc \
      $benchmarks)"

# Renaissance JSON has results.<bench>.results[].duration_ns; compute median per bench.
per_bench="{}"
if [[ -f "$result_json" ]]; then
  per_bench="$(jq '
    .results // {} |
    to_entries | map({
      key: .key,
      value: {
        median_ms: (
          [ .value.results[]?.duration_ns ]
          | map(. / 1e6)
          | sort
          | if length == 0 then null
            else
              if length % 2 == 1 then .[(length-1)/2]
              else (.[length/2-1] + .[length/2]) / 2
              end
            end
        ),
        n: ( .value.results | length // 0 )
      }
    }) | from_entries
  ' "$result_json" 2>/dev/null || echo "{}")"
fi

java_version="$(java -version 2>&1 | head -n1 | awk -F'"' '{print $2}')"
jq \
  --arg version "$version" \
  --arg benchmarks "$benchmarks" \
  --argjson reps "$repetitions" \
  --arg tool "renaissance" \
  --arg java_version "$java_version" \
  --argjson per_bench "$per_bench" \
  '. + {
    extra: {
      tool: $tool,
      project: "renaissance",
      version: $version,
      benchmarks: $benchmarks,
      repetitions: $reps,
      java_version: $java_version,
      per_benchmark: $per_bench
    }
  }' <<<"$iter_json"
