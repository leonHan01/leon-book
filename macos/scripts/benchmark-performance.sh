#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
MACOS_DIR="${SCRIPT_DIR:h}"
BUILD_ROOT="${TMPDIR%/}/leon-book-swiftpm-performance"

mkdir -p \
    "${BUILD_ROOT}/cache" \
    "${BUILD_ROOT}/config" \
    "${BUILD_ROOT}/security" \
    "${BUILD_ROOT}/scratch" \
    "${BUILD_ROOT}/modules"
export CLANG_MODULE_CACHE_PATH="${BUILD_ROOT}/modules"

source "${SCRIPT_DIR}/swift-sdk.sh"

SWIFT_ARGUMENTS=(
    --package-path "${MACOS_DIR}"
    --cache-path "${BUILD_ROOT}/cache"
    --config-path "${BUILD_ROOT}/config"
    --security-path "${BUILD_ROOT}/security"
    --scratch-path "${BUILD_ROOT}/scratch"
    --manifest-cache local
    --disable-sandbox
)

LEON_BOOK_PERFORMANCE_BENCHMARKS=1 \
LEON_BOOK_TEST_FILTER="${LEON_BOOK_TEST_FILTER:-Benchmark}" \
swift run \
    "${SWIFT_ARGUMENTS[@]}" \
    "${SDK_ARGUMENTS[@]}" \
    --configuration release \
    -Xswiftc -enable-testing \
    LeonBookTests
