#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
MACOS_DIR="${SCRIPT_DIR:h}"
BUILD_ROOT="${TMPDIR%/}/notebook36-swiftpm-tests"
SDK_ARGUMENTS=()

mkdir -p "${BUILD_ROOT}/cache" "${BUILD_ROOT}/config" "${BUILD_ROOT}/security" "${BUILD_ROOT}/scratch" "${BUILD_ROOT}/modules"
export CLANG_MODULE_CACHE_PATH="${BUILD_ROOT}/modules"

if [[ -n "${NOTEBOOK36_SDK_PATH:-}" ]]; then
    SDK_ARGUMENTS=(--sdk "${NOTEBOOK36_SDK_PATH}")
fi

SWIFT_ARGUMENTS=(
    --package-path "${MACOS_DIR}" \
    --cache-path "${BUILD_ROOT}/cache" \
    --config-path "${BUILD_ROOT}/config" \
    --security-path "${BUILD_ROOT}/security" \
    --scratch-path "${BUILD_ROOT}/scratch" \
    --manifest-cache local \
    --disable-sandbox
)

swift build "${SWIFT_ARGUMENTS[@]}" "${SDK_ARGUMENTS[@]}"
swift run "${SWIFT_ARGUMENTS[@]}" "${SDK_ARGUMENTS[@]}" --skip-build Notebook36Checks
