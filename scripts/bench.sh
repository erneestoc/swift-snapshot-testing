#!/usr/bin/env bash
#
# Run the SnapshotTesting benchmark harness in serial and parallel modes,
# emitting one CSV per mode under bench-results/<git-sha>-<mode>.csv.
#
# Usage:
#   scripts/bench.sh                       # full sweep (serial + parallel-4 + parallel-8)
#   scripts/bench.sh --quick               # smoke run with --scale 0.1
#   scripts/bench.sh --only NAME[,NAME...] # restrict to specific scenarios
#   scripts/bench.sh --suite ios|all       # opt-in iOS-resolution suite
#   BENCH_OUT_DIR=/tmp/x scripts/bench.sh  # override output dir
#
# Exit non-zero if any mode fails.

set -euo pipefail

cd "$(dirname "$0")/.."

EXTRA_ARGS=()
QUICK=0
SUITE="default"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)
      QUICK=1
      shift
      ;;
    --only)
      shift
      EXTRA_ARGS+=(--only "$1")
      shift
      ;;
    --suite)
      shift
      SUITE="$1"
      EXTRA_ARGS+=(--suite "$1")
      shift
      ;;
    -h|--help)
      sed -n '2,13p' "$0"
      exit 0
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "$QUICK" -eq 1 ]]; then
  EXTRA_ARGS+=(--scale 0.1)
fi

GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
DIRTY=""
if ! git diff --quiet 2>/dev/null; then
  DIRTY="-dirty"
fi
OUT_DIR="${BENCH_OUT_DIR:-bench-results}"
mkdir -p "$OUT_DIR"

echo "==> building release"
swift build -c release --product SnapshotTestingBenchmarks

BIN="$(swift build -c release --product SnapshotTestingBenchmarks --show-bin-path)/SnapshotTestingBenchmarks"

# SnapshotTesting links against XCTest + swift-testing transitively. The toolchain ships
# those frameworks under the platform Developer dir; teach dyld how to find them when we
# run the bench binary directly.
PLATFORM_DIR="$(xcrun --show-sdk-platform-path)"
export DYLD_FRAMEWORK_PATH="$PLATFORM_DIR/Developer/Library/Frameworks:$PLATFORM_DIR/Developer/Library/PrivateFrameworks${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
export DYLD_LIBRARY_PATH="$PLATFORM_DIR/Developer/usr/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

SUITE_TAG=""
if [[ "$SUITE" == "ios" ]]; then
  SUITE_TAG="-ios"
elif [[ "$SUITE" == "all" ]]; then
  SUITE_TAG="-all"
fi

run_mode() {
  local mode="$1"
  shift
  local out="$OUT_DIR/${GIT_SHA}${DIRTY}${SUITE_TAG}-${mode}.csv"
  echo "==> mode=$mode -> $out"
  "$BIN" "$@" "${EXTRA_ARGS[@]}" --out "$out"
}

run_mode serial      --serial
run_mode parallel-4  --parallel 4
run_mode parallel-8  --parallel 8

echo "==> done"
ls -la "$OUT_DIR" | grep "$GIT_SHA"
