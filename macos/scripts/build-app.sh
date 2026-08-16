#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
MACOS_DIR="${SCRIPT_DIR:h}"
APP_NAME="leon-book"
EXECUTABLE_NAME="LeonBook"
APP_BUNDLE="${MACOS_DIR}/dist/${APP_NAME}.app"
BUILD_ROOT="${TMPDIR%/}/leon-book-swiftpm"
STAGING_APP="${BUILD_ROOT}/staging/${APP_NAME}.app"
CONTENTS_DIR="${STAGING_APP}/Contents"
SDK_ARGUMENTS=()

mkdir -p "${BUILD_ROOT}/cache" "${BUILD_ROOT}/config" "${BUILD_ROOT}/security" "${BUILD_ROOT}/scratch" "${BUILD_ROOT}/modules"
export CLANG_MODULE_CACHE_PATH="${BUILD_ROOT}/modules"

SDK_PATH="${LEON_BOOK_SDK_PATH:-}"
if [[ -n "${SDK_PATH}" ]]; then
    SDK_ARGUMENTS=(--sdk "${SDK_PATH}")
fi

SWIFT_ARGUMENTS=(
    --package-path "${MACOS_DIR}"
    --cache-path "${BUILD_ROOT}/cache"
    --config-path "${BUILD_ROOT}/config"
    --security-path "${BUILD_ROOT}/security"
    --scratch-path "${BUILD_ROOT}/scratch"
    --manifest-cache local
    --disable-sandbox
)

swift build "${SWIFT_ARGUMENTS[@]}" "${SDK_ARGUMENTS[@]}" --configuration release
BIN_PATH="$(swift build "${SWIFT_ARGUMENTS[@]}" "${SDK_ARGUMENTS[@]}" --configuration release --show-bin-path)"

rm -rf "${STAGING_APP}" "${APP_BUNDLE}"
mkdir -p "${CONTENTS_DIR}/MacOS" "${CONTENTS_DIR}/Resources"
COPYFILE_DISABLE=1 cp "${BIN_PATH}/${EXECUTABLE_NAME}" "${CONTENTS_DIR}/MacOS/${EXECUTABLE_NAME}"
COPYFILE_DISABLE=1 cp "${MACOS_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"
COPYFILE_DISABLE=1 cp "${MACOS_DIR}/Resources/Notes.icns" "${CONTENTS_DIR}/Resources/Notes.icns"
codesign --force --sign - --timestamp=none "${STAGING_APP}"
codesign --verify --deep --strict "${STAGING_APP}"

mkdir -p "${MACOS_DIR}/dist"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr --noqtn --noacl "${STAGING_APP}" "${APP_BUNDLE}"
find "${APP_BUNDLE}" -name '._*' -delete
codesign --verify --deep --strict "${APP_BUNDLE}"

echo "Built ${APP_BUNDLE}"
