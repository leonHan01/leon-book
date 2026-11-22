#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
MACOS_DIR="${SCRIPT_DIR:h}"
source "${SCRIPT_DIR}/swift-cache.sh"
source "${SCRIPT_DIR}/swift-sdk.sh"
BUILD_ROOT="$(leonbook_build_root tests)"
mkdir -p "${BUILD_ROOT}/modules"
export CLANG_MODULE_CACHE_PATH="${BUILD_ROOT}/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="${BUILD_ROOT}/modules"
SWIFT_ARGUMENTS=(--package-path "${MACOS_DIR}" --scratch-path "${BUILD_ROOT}/scratch"
    --cache-path "${BUILD_ROOT}/cache" --config-path "${BUILD_ROOT}/config"
    --security-path "${BUILD_ROOT}/security" --manifest-cache local --disable-sandbox)
swift build "${SWIFT_ARGUMENTS[@]}" "${SDK_ARGUMENTS[@]}" --jobs "${LEON_BOOK_BUILD_JOBS:-4}"
BIN_PATH="$(swift build "${SWIFT_ARGUMENTS[@]}" "${SDK_ARGUMENTS[@]}" --show-bin-path)"
export LEON_CHAT_CLI_PATH="${BIN_PATH}/LeonBookCLI"
export LEON_CHAT_DEFAULTS_SUITE="com.leon-book.chat.tests.$$.${RANDOM}"
cd "${MACOS_DIR}"
mkdir -p .build
FAILED_SUITES=()
for CHECK in Message Markdown Math TableLayout RichMarkdown Image Composer Archive ArchiveFlow Switching Search ContextMemory Integration; do
    PRODUCT="LeonChat${CHECK}Checks"
    if ! "${BIN_PATH}/${PRODUCT}"; then FAILED_SUITES+=("${PRODUCT}"); fi
done
if (( ${#FAILED_SUITES[@]} > 0 )); then
    print -u2 -- "Failed chat suites: ${FAILED_SUITES[*]}"
    exit 1
fi
