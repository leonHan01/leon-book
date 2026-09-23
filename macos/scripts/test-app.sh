#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
MACOS_DIR="${SCRIPT_DIR:h}"
BUILD_ROOT="${TMPDIR%/}/leon-book-swiftpm-tests"

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

swift build "${SWIFT_ARGUMENTS[@]}" "${SDK_ARGUMENTS[@]}"
# Build failures still stop immediately; a failed suite must not hide the
# results of the remaining independent checks.
FAILED_SUITES=()
for TEST_PRODUCT in LeonBookModuleTests LeonBookTests LeonBookChecks LeonBookStoreChecks; do
    if ! swift run "${SWIFT_ARGUMENTS[@]}" "${SDK_ARGUMENTS[@]}" --skip-build "${TEST_PRODUCT}"; then
        FAILED_SUITES+=("${TEST_PRODUCT}")
    fi
done
if (( ${#FAILED_SUITES[@]} > 0 )); then
    print -u2 -- "Failed suites: ${FAILED_SUITES[*]}"
    exit 1
fi
