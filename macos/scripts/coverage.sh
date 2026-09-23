#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
MACOS_DIR="${SCRIPT_DIR:h}"
BUILD_ROOT="${TMPDIR%/}/leon-book-swiftpm-coverage"

mkdir -p "${BUILD_ROOT}/cache" "${BUILD_ROOT}/config" "${BUILD_ROOT}/security" "${BUILD_ROOT}/scratch" "${BUILD_ROOT}/modules"
export CLANG_MODULE_CACHE_PATH="${BUILD_ROOT}/modules"

source "${SCRIPT_DIR}/swift-sdk.sh"

SWIFT_ARGUMENTS=(
    --package-path "${MACOS_DIR}" \
    --cache-path "${BUILD_ROOT}/cache" \
    --config-path "${BUILD_ROOT}/config" \
    --security-path "${BUILD_ROOT}/security" \
    --scratch-path "${BUILD_ROOT}/scratch" \
    --manifest-cache local \
    --disable-sandbox
)

swift build --enable-code-coverage "${SWIFT_ARGUMENTS[@]}" "${SDK_ARGUMENTS[@]}"

UNIT_TEST_BINARY="${BUILD_ROOT}/scratch/arm64-apple-macosx/debug/LeonBookTests"
LLVM_PROFILE_FILE="${BUILD_ROOT}/coverage-%p.profraw" "${UNIT_TEST_BINARY}"

xcrun llvm-profdata merge -sparse "${BUILD_ROOT}"/coverage-*.profraw -o "${BUILD_ROOT}/coverage.profdata"
xcrun llvm-cov report "${UNIT_TEST_BINARY}" \
    -instr-profile="${BUILD_ROOT}/coverage.profdata" \
    "${MACOS_DIR}"/Sources/LeonBook/*.swift
