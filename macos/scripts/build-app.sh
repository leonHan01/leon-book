#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
MACOS_DIR="${SCRIPT_DIR:h}"
APP_NAME="leon-book"
EXECUTABLE_NAME="LeonBook"
BUILD_CONFIGURATION="${LEON_BOOK_BUILD_CONFIGURATION:-release}"
case "${BUILD_CONFIGURATION}" in
    debug|release) ;;
    *) print -u2 -- "Invalid build configuration: ${BUILD_CONFIGURATION} (expected debug or release)"; exit 2 ;;
esac
BUILD_SYSTEM="${LEON_BOOK_BUILD_SYSTEM:-}"
if [[ -z "${BUILD_SYSTEM}" ]]; then
    if [[ "${BUILD_CONFIGURATION}" == debug ]] && \
        swift build --help 2>/dev/null | /usr/bin/grep -E '^[[:space:]]+native[[:space:]]+-' >/dev/null; then
        BUILD_SYSTEM=native
    else
        BUILD_SYSTEM=default
    fi
fi
case "${BUILD_SYSTEM}" in
    default|native|swiftbuild) ;;
    *) print -u2 -- "Invalid build system: ${BUILD_SYSTEM} (expected default, native or swiftbuild)"; exit 2 ;;
esac
APP_BUNDLE="${MACOS_DIR}/dist/${APP_NAME}.app"
BUILD_ROOT="${TMPDIR%/}/leon-book-swiftpm"
if [[ "${BUILD_SYSTEM}" != default ]]; then
    # Keep the local native edit/build loop independent of Release/toolchain
    # builds, including their SwiftPM lock and module cache.
    BUILD_ROOT="${BUILD_ROOT}-${BUILD_SYSTEM}"
fi

mkdir -p "${BUILD_ROOT}/cache" "${BUILD_ROOT}/config" "${BUILD_ROOT}/security" "${BUILD_ROOT}/scratch" "${BUILD_ROOT}/modules"
export CLANG_MODULE_CACHE_PATH="${BUILD_ROOT}/modules"
# Preserve the build-start time so edits made during compilation still make
# the packaged app stale, even when Swift reused an older executable.
BUILD_INFO="$(mktemp "${BUILD_ROOT}/build-info.XXXXXX")"
STAGING_ROOT="$(mktemp -d "${BUILD_ROOT}/staging.XXXXXX")"
STAGING_APP="${STAGING_ROOT}/${APP_NAME}.app"
CONTENTS_DIR="${STAGING_APP}/Contents"
trap 'rm -f "${BUILD_INFO}"; rm -rf "${STAGING_ROOT}"' EXIT
print -r -- "${BUILD_CONFIGURATION}" > "${BUILD_INFO}"
BUILD_STARTED_AT=$SECONDS
print -- "[INFO] Swift ${BUILD_CONFIGURATION} 构建（${BUILD_SYSTEM} 引擎）…"

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
if [[ "${BUILD_SYSTEM}" != default ]]; then
    SWIFT_ARGUMENTS+=(--build-system "${BUILD_SYSTEM}")
fi

swift build "${SWIFT_ARGUMENTS[@]}" "${SDK_ARGUMENTS[@]}" \
    --configuration "${BUILD_CONFIGURATION}" \
    --product "${EXECUTABLE_NAME}"
swift build "${SWIFT_ARGUMENTS[@]}" "${SDK_ARGUMENTS[@]}" \
    --configuration "${BUILD_CONFIGURATION}" --product LeonBookCLI
BIN_PATH="$(swift build "${SWIFT_ARGUMENTS[@]}" "${SDK_ARGUMENTS[@]}" --configuration "${BUILD_CONFIGURATION}" --show-bin-path)"
print -- "[INFO] Swift 编译完成（耗时 $((SECONDS - BUILD_STARTED_AT)) 秒）。"
PACKAGING_STARTED_AT=$SECONDS

mkdir -p "${CONTENTS_DIR}/MacOS" "${CONTENTS_DIR}/Resources"
COPYFILE_DISABLE=1 cp "${BIN_PATH}/${EXECUTABLE_NAME}" "${CONTENTS_DIR}/MacOS/${EXECUTABLE_NAME}"
# Names differing only by case refer to the same file on default macOS volumes.
COPYFILE_DISABLE=1 cp "${BIN_PATH}/LeonBookCLI" "${CONTENTS_DIR}/MacOS/LeonBookCLI"
COPYFILE_DISABLE=1 cp "${MACOS_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"
COPYFILE_DISABLE=1 cp "${MACOS_DIR}/Resources/Notes.icns" "${CONTENTS_DIR}/Resources/Notes.icns"
COPYFILE_DISABLE=1 cp -p "${BUILD_INFO}" "${CONTENTS_DIR}/Resources/leonbook-build-configuration"
print -r -- "${BUILD_SYSTEM}" > "${CONTENTS_DIR}/Resources/leonbook-build-system"
for LOCALIZATION_DIR in "${MACOS_DIR}/Sources/LeonBook/Resources/"*.lproj; do
    [[ -d "${LOCALIZATION_DIR}" ]] || continue
    COPYFILE_DISABLE=1 cp -R "${LOCALIZATION_DIR}" "${CONTENTS_DIR}/Resources/"
done
if [[ -d "${BIN_PATH}/LeonBookMac_LeonBook.bundle" ]]; then
    COPYFILE_DISABLE=1 cp -R "${BIN_PATH}/LeonBookMac_LeonBook.bundle" "${CONTENTS_DIR}/Resources/"
else
    print -u2 -- "Missing SwiftPM resource bundle: ${BIN_PATH}/LeonBookMac_LeonBook.bundle"
    exit 1
fi
codesign --force --sign - --timestamp=none "${STAGING_APP}"
codesign --verify --deep --strict "${STAGING_APP}"

mkdir -p "${MACOS_DIR}/dist"
# Only publishing is serialized across engines; compilation uses independent
# caches. The OS releases this lock even if the shell is interrupted.
PUBLISH_LOCK="${TMPDIR%/}/leon-book-swiftpm-publish.lock"
touch "${PUBLISH_LOCK}"
zmodload zsh/system
zsystem flock -t 30 -f PUBLISH_LOCK_FD "${PUBLISH_LOCK}"
rm -rf "${APP_BUNDLE}"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr --noqtn --noacl "${STAGING_APP}" "${APP_BUNDLE}"
find "${APP_BUNDLE}" -name '._*' -delete
codesign --verify --deep --strict "${APP_BUNDLE}"
zsystem flock -u "${PUBLISH_LOCK_FD}"

print -- "[INFO] 打包与签名完成（耗时 $((SECONDS - PACKAGING_STARTED_AT)) 秒）。"
echo "Built ${APP_BUNDLE}"
