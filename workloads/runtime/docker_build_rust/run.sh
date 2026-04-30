#!/usr/bin/env bash
# `docker build` of a multi-stage Rust image.
#
# Usage:
#   run.sh --variant {cold|warm} [--tag devbench/dockerload:latest]
#
# cold  : `docker builder prune -f` first; every layer rebuilds.
# warm  : second build with the full cache; should be near-instant.
#
# This exposes the Mac VM overhead honestly vs native Linux dockerd; also exposes
# the `cargo fetch` network + registry-index step on cold builds.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$HERE/../../../scripts/common"
# shellcheck source=../../../scripts/common/lib.sh
source "$COMMON/lib.sh"

require_cmd docker
require_cmd jq

variant="cold"
tag="devbench/dockerload:latest"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) variant="$2"; shift 2 ;;
    --tag)     tag="$2";     shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

# The build context is the directory of this script (contains Dockerfile + src/).
# We build with BuildKit enabled (default in modern docker, explicit for older).
case "$variant" in
  cold)
    log_info "pruning builder cache"
    docker builder prune -af >/dev/null 2>&1 || log_warn "builder prune failed (non-root? remote?)"
    # Also remove the resulting image if present so `docker tag` doesn't hit local cache.
    docker rmi -f "$tag" >/dev/null 2>&1 || true
    ;;
  warm)
    log_info "pre-build (warm setup)"
    DOCKER_BUILDKIT=1 docker build --quiet --tag "$tag" "$HERE" >/tmp/devbench-docker-warm-prep.log 2>&1
    ;;
  *) die "unknown variant: $variant (expected cold|warm)" ;;
esac

docker_version="$(docker --version | awk -F'[ ,]' '{print $3}')"
runtime="dockerd"
# On Mac with OrbStack, report that; on Linux, docker-host is usually dockerd.
if docker info 2>/dev/null | grep -qi 'orbstack'; then runtime="orbstack"; fi

log_info "build: variant=$variant tag=$tag runtime=$runtime"
iter_json="$("$COMMON/time_run.sh" \
  --id "runtime.docker_build_rust.$variant" \
  --cwd "$HERE" \
  -- env DOCKER_BUILDKIT=1 docker build --tag "$tag" .)"

jq \
  --arg variant "$variant" \
  --arg tag "$tag" \
  --arg tool "docker build" \
  --arg docker_version "$docker_version" \
  --arg runtime "$runtime" \
  '. + {
    extra: {
      tool: $tool,
      project: "docker_build_rust",
      variant: $variant,
      image_tag: $tag,
      docker_version: $docker_version,
      runtime: $runtime
    }
  }' <<<"$iter_json"
