#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
MACOS_DIR="${SCRIPT_DIR:h}"
BUILD_ROOT="${TMPDIR:-/tmp/}leon-book-swiftpm-tests"
CLI="${BUILD_ROOT}/scratch/debug/LeonBookCLI"

if [[ ! -x "${CLI}" || "${MACOS_DIR}/Package.swift" -nt "${CLI}" ]] || \
    [[ -n "$(find "${MACOS_DIR}/Sources" -type f -newer "${CLI}" -print -quit 2>/dev/null)" ]]; then
    mkdir -p "${BUILD_ROOT}/cache" "${BUILD_ROOT}/config" "${BUILD_ROOT}/security" "${BUILD_ROOT}/scratch" "${BUILD_ROOT}/modules"
    export CLANG_MODULE_CACHE_PATH="${BUILD_ROOT}/modules"
    source "${SCRIPT_DIR}/swift-sdk.sh" >&2
    swift build --package-path "${MACOS_DIR}" --cache-path "${BUILD_ROOT}/cache" \
        --config-path "${BUILD_ROOT}/config" --security-path "${BUILD_ROOT}/security" \
        --scratch-path "${BUILD_ROOT}/scratch" --manifest-cache local --disable-sandbox \
        "${SDK_ARGUMENTS[@]}" --product LeonBookCLI >&2
fi
exec "${CLI}" "$@"
