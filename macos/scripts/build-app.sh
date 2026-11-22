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
source "${SCRIPT_DIR}/swift-cache.sh"
BUILD_ROOT="$(leonbook_build_root "${BUILD_SYSTEM}")"

mkdir -p "${BUILD_ROOT}/cache" "${BUILD_ROOT}/config" "${BUILD_ROOT}/security" "${BUILD_ROOT}/scratch" "${BUILD_ROOT}/modules"
export CLANG_MODULE_CACHE_PATH="${BUILD_ROOT}/modules"
# Preserve the build-start time so edits made during compilation still make
# the packaged app stale, even when Swift reused an older executable.
BUILD_INFO="$(mktemp "${BUILD_ROOT}/build-info.XXXXXX")"
STAGING_ROOT="$(mktemp -d "${BUILD_ROOT}/staging.XXXXXX")"
STAGING_APP="${STAGING_ROOT}/${APP_NAME}.app"
CONTENTS_DIR="${STAGING_APP}/Contents"
INPUT_STATE="${STAGING_ROOT}/build-inputs.json"
# zsh's errexit inside a function does not run the top-level EXIT trap.
trap 'rm -f "${BUILD_INFO}"; rm -rf "${STAGING_ROOT}"' EXIT ZERR
print -r -- "${BUILD_CONFIGURATION}" > "${BUILD_INFO}"
BUILD_STARTED_AT=$SECONDS
python3 "${SCRIPT_DIR}/build-state.py" capture "${MACOS_DIR}" "${INPUT_STATE}"

# Release packaging may use an Apple identity. An explicit team is required
# and the designated requirement survives changes to the executable and leaf certificate.
load_signing_configuration() {
    local fields
    fields="$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))["native"]; print(s["@codesign-identity"]); print(s["@codesign-team"])' "${INPUT_STATE}")"
    signing_identity="${fields%%$'\n'*}"
    signing_team="${fields#*$'\n'}"
    if [[ "${signing_identity}" != - ]]; then
        if [[ -z "${signing_identity}" || ! "${signing_team}" =~ '^[A-Z0-9]{10}$' ]]; then
            print -u2 -- 'Apple signing requires LEON_BOOK_CODESIGN_IDENTITY and a 10-character LEON_BOOK_CODESIGN_TEAM_ID.'
            return 1
        fi
        signing_requirement="anchor apple generic and certificate leaf[subject.OU] = \"${signing_team}\" and ((certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists) or (certificate 1[field.1.2.840.113635.100.6.2.1] exists and (certificate leaf[field.1.2.840.113635.100.6.1.12] exists or certificate leaf[field.1.2.840.113635.100.6.1.7] exists)))"
    fi
}

verify_app() {
    local target="$1"
    codesign --verify --deep --strict "${target}" || return 1
    if [[ "${signing_identity}" != - ]]; then
        codesign --verify --strict -R "=${signing_requirement}" "${target}" || return 1
        codesign --verify --strict -R "=${signing_requirement}" "${target}/Contents/MacOS/LeonBookCLI" || return 1
    fi
}

load_signing_configuration

acquire_publish_lock() {
    mkdir -p "${MACOS_DIR}/dist"
    # The destination owns the lock, regardless of TMPDIR or cache overrides.
    local lock_file="${MACOS_DIR}/dist/.leonbook-publish.lock"
    touch "${lock_file}"
    zmodload zsh/system
    zsystem flock -t 30 -f PUBLISH_LOCK_FD "${lock_file}"
}

sign_and_publish() {
    python3 "${SCRIPT_DIR}/build-state.py" sync-editor "${MACOS_DIR}" "${STAGING_APP}" "${INPUT_STATE}"
    COPYFILE_DISABLE=1 cp "${INPUT_STATE}" "${CONTENTS_DIR}/Resources/leonbook-build-inputs.json"
    COPYFILE_DISABLE=1 cp -p "${BUILD_INFO}" "${CONTENTS_DIR}/Resources/leonbook-build-configuration"
    if [[ "${signing_identity}" == - ]]; then
        codesign --force --sign - --timestamp=none "${STAGING_APP}"
    else
        codesign --force --sign "${signing_identity}" --timestamp=none \
            --identifier com.leon-book.macos.cli \
            --requirements "=designated => identifier \"com.leon-book.macos.cli\" and (${signing_requirement})" \
            "${CONTENTS_DIR}/MacOS/LeonBookCLI"
        codesign --force --sign "${signing_identity}" --timestamp=none \
            --requirements "=designated => identifier \"com.leon-book.macos\" and (${signing_requirement})" "${STAGING_APP}"
    fi
    verify_app "${STAGING_APP}"

    [[ -n "${PUBLISH_LOCK_FD:-}" ]] || acquire_publish_lock
    # Copy and verify on the destination volume before replacing the old app.
    local install_root
    install_root="$(mktemp -d "${MACOS_DIR}/dist/.leonbook-install.XXXXXX")"
    if ! COPYFILE_DISABLE=1 ditto --norsrc --noextattr --noqtn --noacl "${STAGING_APP}" "${install_root}/${APP_NAME}.app" || \
        ! verify_app "${install_root}/${APP_NAME}.app"; then
        rm -rf "${install_root}"
        return 1
    fi
    [[ ! -e "${APP_BUNDLE}" ]] || mv "${APP_BUNDLE}" "${install_root}/previous.app"
    if ! mv "${install_root}/${APP_NAME}.app" "${APP_BUNDLE}"; then
        [[ ! -e "${install_root}/previous.app" ]] || mv "${install_root}/previous.app" "${APP_BUNDLE}"
        rm -rf "${install_root}"
        return 1
    fi
    rm -rf "${install_root}"
    zsystem flock -u "${PUBLISH_LOCK_FD}"
    unset PUBLISH_LOCK_FD
}

if [[ "${LEON_BOOK_FORCE_SWIFT_BUILD:-0}" != 1 ]] && \
    [[ "$(python3 "${SCRIPT_DIR}/build-state.py" status "${MACOS_DIR}" "${APP_BUNDLE}" "${BUILD_CONFIGURATION}" "${BUILD_SYSTEM}" "${INPUT_STATE}")" == resources ]]; then
    # Keep the source app stable while copying it; another engine may be publishing.
    acquire_publish_lock
    python3 "${SCRIPT_DIR}/build-state.py" capture "${MACOS_DIR}" "${INPUT_STATE}"
    load_signing_configuration
    LOCKED_STATUS="$(python3 "${SCRIPT_DIR}/build-state.py" status "${MACOS_DIR}" "${APP_BUNDLE}" "${BUILD_CONFIGURATION}" "${BUILD_SYSTEM}" "${INPUT_STATE}")"
    if [[ "${LOCKED_STATUS}" == unchanged ]]; then
        zsystem flock -u "${PUBLISH_LOCK_FD}"
        print -- '[INFO] 另一构建已更新应用，无需重复更新。'
        exit 0
    fi
    if [[ "${LOCKED_STATUS}" == resources ]] && \
        codesign --verify --deep --strict "${APP_BUNDLE}"; then
        print -- '[INFO] 仅编辑器资源变化，更新资源并重新签名，跳过 Swift 编译…'
        COPYFILE_DISABLE=1 cp -R "${APP_BUNDLE}" "${STAGING_APP}"
        sign_and_publish
        print -- "[INFO] 编辑器资源更新完成（耗时 $((SECONDS - BUILD_STARTED_AT)) 秒）。"
        exit 0
    fi
    zsystem flock -u "${PUBLISH_LOCK_FD}"
    unset PUBLISH_LOCK_FD
fi

print -- "[INFO] Swift ${BUILD_CONFIGURATION} 构建（${BUILD_SYSTEM} 引擎）…"
print -- "[INFO] 构建缓存：${BUILD_ROOT}"

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
MOBILE_SOURCE_DIR="${MACOS_DIR:h}/mobile"
MOBILE_RESOURCES="${CONTENTS_DIR}/Resources/MobileSync"
mkdir -p "${MOBILE_RESOURCES}/node_modules"
COPYFILE_DISABLE=1 cp "${MOBILE_SOURCE_DIR}/package.json" "${MOBILE_RESOURCES}/package.json"
COPYFILE_DISABLE=1 cp -R "${MOBILE_SOURCE_DIR}/server" "${MOBILE_SOURCE_DIR}/shared" "${MOBILE_RESOURCES}/"
for dependency in busboy streamsearch; do
    if [[ -d "${MOBILE_SOURCE_DIR}/node_modules/${dependency}" ]]; then
        COPYFILE_DISABLE=1 cp -R "${MOBILE_SOURCE_DIR}/node_modules/${dependency}" "${MOBILE_RESOURCES}/node_modules/"
    fi
done
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
for RESOURCE_BUNDLE in LeonBookMac_LeonChat.bundle SwiftMath_SwiftMath.bundle; do
    if [[ ! -d "${BIN_PATH}/${RESOURCE_BUNDLE}" ]]; then
        print -u2 -- "Missing chat resource bundle: ${RESOURCE_BUNDLE}"
        exit 1
    fi
    COPYFILE_DISABLE=1 cp -R "${BIN_PATH}/${RESOURCE_BUNDLE}" "${CONTENTS_DIR}/Resources/"
done
COPYFILE_DISABLE=1 cp "${MACOS_DIR}/Vendor/SwiftMath/LICENSE" "${CONTENTS_DIR}/Resources/SwiftMath-LICENSE.txt"
sign_and_publish

print -- "[INFO] 打包与签名完成（耗时 $((SECONDS - PACKAGING_STARTED_AT)) 秒）。"
echo "Built ${APP_BUNDLE}"
