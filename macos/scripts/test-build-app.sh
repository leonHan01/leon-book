#!/bin/zsh

set -euo pipefail
unsetopt BG_NICE

SCRIPT_DIR="${0:A:h}"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp/}leon-book-packaging.XXXXXX")"
trap 'rm -rf "${FIXTURE_ROOT}"' EXIT
FIXTURE_MACOS_DIR="${FIXTURE_ROOT}/project with spaces/macos"
FIXTURE_PRODUCTS="${FIXTURE_ROOT}/products"

# Exercise the real packaging steps with tiny executables, without compiling
# Swift or opening an application window.
mkdir -p "${FIXTURE_MACOS_DIR}/scripts" "${FIXTURE_MACOS_DIR}/Resources" \
    "${FIXTURE_MACOS_DIR}/Sources/LeonBook/Resources/en.lproj" \
    "${FIXTURE_PRODUCTS}/LeonBookMac_LeonBook.bundle" \
    "${FIXTURE_ROOT}/bin" "${FIXTURE_ROOT}/tmp"
cp "${SCRIPT_DIR}/build-app.sh" "${FIXTURE_MACOS_DIR}/scripts/build-app.sh"
print -r -- 'SDK_ARGUMENTS=()' > "${FIXTURE_MACOS_DIR}/scripts/swift-sdk.sh"
touch "${FIXTURE_MACOS_DIR}/Resources/Info.plist" "${FIXTURE_MACOS_DIR}/Resources/Notes.icns"

cat > "${FIXTURE_PRODUCTS}/LeonBook" <<'EOF'
#!/bin/sh
printf 'GUI fixture\n'
EOF
cat > "${FIXTURE_PRODUCTS}/LeonBookCLI" <<'EOF'
#!/bin/sh
printf 'CLI fixture\n'
EOF
cat > "${FIXTURE_ROOT}/bin/swift" <<'EOF'
#!/bin/sh
if [ "${2:-}" = --help ]; then
    if [ "${LEON_BOOK_BUILD_TEST_NATIVE_AVAILABLE:-1}" = 1 ]; then
        printf '        native - Native Build System\n'
    fi
    printf '        swiftbuild - Swift Build engine\n'
    exit 0
fi
printf '%s\n' "$*" >> "$LEON_BOOK_BUILD_TEST_CALLS"
if [ -n "${LEON_BOOK_BUILD_TEST_EDIT:-}" ]; then
    touch "$LEON_BOOK_BUILD_TEST_EDIT"
fi
for argument in "$@"; do
    if [ "$argument" = '--show-bin-path' ]; then
        printf '%s\n' "$LEON_BOOK_BUILD_TEST_PRODUCTS"
        exit 0
    fi
done
EOF
cat > "${FIXTURE_ROOT}/bin/codesign" <<'EOF'
#!/bin/sh
if [ "${LEON_BOOK_BUILD_TEST_SIGN_FAIL:-0}" = 1 ]; then
    exit 1
fi
exit 0
EOF
cat > "${FIXTURE_ROOT}/bin/ditto" <<'EOF'
#!/bin/sh
set -eu
if [ -n "${LEON_BOOK_BUILD_TEST_INSTALL_GUARD:-}" ]; then
    mkdir "$LEON_BOOK_BUILD_TEST_INSTALL_GUARD"
    trap 'rmdir "$LEON_BOOK_BUILD_TEST_INSTALL_GUARD"' EXIT
    printf 'install\n' >> "$LEON_BOOK_BUILD_TEST_INSTALL_LOG"
    sleep 0.2
fi
/usr/bin/ditto "$@"
EOF
chmod +x "${FIXTURE_PRODUCTS}/LeonBook" "${FIXTURE_PRODUCTS}/LeonBookCLI" \
    "${FIXTURE_ROOT}/bin/swift" "${FIXTURE_ROOT}/bin/codesign" "${FIXTURE_ROOT}/bin/ditto"

PATH="${FIXTURE_ROOT}/bin:$PATH" TMPDIR="${FIXTURE_ROOT}/tmp/" \
    LEON_BOOK_BUILD_TEST_PRODUCTS="${FIXTURE_PRODUCTS}" \
    LEON_BOOK_BUILD_TEST_CALLS="${FIXTURE_ROOT}/swift-calls" \
    LEON_BOOK_BUILD_CONFIGURATION=release \
    LEON_BOOK_BUILD_SYSTEM= \
    /bin/zsh "${FIXTURE_MACOS_DIR}/scripts/build-app.sh"

PACKAGED_MACOS_DIR="${FIXTURE_MACOS_DIR}/dist/leon-book.app/Contents/MacOS"
PACKAGED_GUI="${PACKAGED_MACOS_DIR}/LeonBook"
if [[ "$("${PACKAGED_GUI}")" != 'GUI fixture' ]]; then
    print -u2 -- 'FAIL: packaging overwrote the GUI executable with the CLI.'
    exit 1
fi

PACKAGED_EXECUTABLES=("${PACKAGED_MACOS_DIR}/"*(.N))
[[ ${#PACKAGED_EXECUTABLES} -eq 2 ]]
for PACKAGED_CLI in "${PACKAGED_EXECUTABLES[@]}"; do
    [[ "${PACKAGED_CLI}" == "${PACKAGED_GUI}" ]] && continue
    # Catch the collision on case-sensitive test volumes as well.
    [[ "${PACKAGED_CLI:t:l}" != "${PACKAGED_GUI:t:l}" ]]
    [[ "$("${PACKAGED_CLI}")" == 'CLI fixture' ]]
done
print -- 'PASS: packaged GUI and CLI remain separate on case-insensitive filesystems.'

PACKAGED_BUILD_INFO="${FIXTURE_MACOS_DIR}/dist/leon-book.app/Contents/Resources/leonbook-build-configuration"
[[ "$(cat "${PACKAGED_BUILD_INFO}")" == release ]]
[[ "$(grep -c -- '--configuration release' "${FIXTURE_ROOT}/swift-calls")" == 3 ]]
PACKAGED_BUILD_SYSTEM="${PACKAGED_BUILD_INFO:h}/leonbook-build-system"
[[ "$(cat "${PACKAGED_BUILD_SYSTEM}")" == default ]]
grep -Fq -- "--scratch-path ${FIXTURE_ROOT}/tmp/leon-book-swiftpm/scratch" "${FIXTURE_ROOT}/swift-calls"
if grep -q -- '--build-system' "${FIXTURE_ROOT}/swift-calls"; then
    print -u2 -- 'FAIL: default Release build overrode the toolchain build engine.'
    exit 1
fi
print -- 'PASS: Release configuration is used for both products and their output path.'

: > "${FIXTURE_ROOT}/swift-calls"
EDITED_SOURCE="${FIXTURE_MACOS_DIR}/Sources/LeonBook/Example.swift"
touch "${EDITED_SOURCE}"
PATH="${FIXTURE_ROOT}/bin:$PATH" TMPDIR="${FIXTURE_ROOT}/tmp/" \
    LEON_BOOK_BUILD_TEST_PRODUCTS="${FIXTURE_PRODUCTS}" \
    LEON_BOOK_BUILD_TEST_CALLS="${FIXTURE_ROOT}/swift-calls" \
    LEON_BOOK_BUILD_TEST_EDIT="${EDITED_SOURCE}" \
    LEON_BOOK_BUILD_CONFIGURATION=debug \
    LEON_BOOK_BUILD_SYSTEM= \
    /bin/zsh "${FIXTURE_MACOS_DIR}/scripts/build-app.sh"
[[ "$(cat "${PACKAGED_BUILD_INFO}")" == debug ]]
[[ "$(grep -c -- '--configuration debug' "${FIXTURE_ROOT}/swift-calls")" == 3 ]]
[[ "$(cat "${PACKAGED_BUILD_SYSTEM}")" == native ]]
[[ "$(grep -c -- '--build-system native' "${FIXTURE_ROOT}/swift-calls")" == 3 ]]
grep -Fq -- "--scratch-path ${FIXTURE_ROOT}/tmp/leon-book-swiftpm-native/scratch" "${FIXTURE_ROOT}/swift-calls"
[[ "${PACKAGED_BUILD_INFO}" -ot "${EDITED_SOURCE}" ]]
print -- 'PASS: Debug configuration is packaged and edits during compilation remain detectable.'
print -- 'PASS: Debug native and default Release builds use independent caches and locks.'

: > "${FIXTURE_ROOT}/swift-calls"
PATH="${FIXTURE_ROOT}/bin:$PATH" TMPDIR="${FIXTURE_ROOT}/tmp/" \
    LEON_BOOK_BUILD_TEST_PRODUCTS="${FIXTURE_PRODUCTS}" \
    LEON_BOOK_BUILD_TEST_CALLS="${FIXTURE_ROOT}/swift-calls" \
    LEON_BOOK_BUILD_CONFIGURATION=debug LEON_BOOK_BUILD_SYSTEM=swiftbuild \
    /bin/zsh "${FIXTURE_MACOS_DIR}/scripts/build-app.sh"
[[ "$(cat "${PACKAGED_BUILD_SYSTEM}")" == swiftbuild ]]
[[ "$(grep -c -- '--build-system swiftbuild' "${FIXTURE_ROOT}/swift-calls")" == 3 ]]
print -- 'PASS: explicit swiftbuild engine is forwarded to both products and path discovery.'

touch "${PACKAGED_BUILD_INFO:h}/installed-sentinel"
if PATH="${FIXTURE_ROOT}/bin:$PATH" TMPDIR="${FIXTURE_ROOT}/tmp/" \
    LEON_BOOK_BUILD_TEST_PRODUCTS="${FIXTURE_PRODUCTS}" \
    LEON_BOOK_BUILD_TEST_CALLS="${FIXTURE_ROOT}/swift-calls" \
    LEON_BOOK_BUILD_CONFIGURATION=debug LEON_BOOK_BUILD_SYSTEM= \
    LEON_BOOK_BUILD_TEST_SIGN_FAIL=1 \
    /bin/zsh "${FIXTURE_MACOS_DIR}/scripts/build-app.sh" > "${FIXTURE_ROOT}/sign-failure.log" 2>&1; then
    print -u2 -- 'FAIL: packaging succeeded despite a signature failure.'
    exit 1
fi
[[ -f "${PACKAGED_BUILD_INFO:h}/installed-sentinel" ]]
[[ "$("${PACKAGED_GUI}")" == 'GUI fixture' ]]
[[ -z "$(find "${FIXTURE_ROOT}/tmp" -type d -name 'staging.*' -print)" ]]
print -- 'PASS: failed signing preserves the installed app and cleans private staging directories.'

: > "${FIXTURE_ROOT}/swift-calls"
PATH="${FIXTURE_ROOT}/bin:$PATH" TMPDIR="${FIXTURE_ROOT}/tmp/" \
    LEON_BOOK_BUILD_TEST_PRODUCTS="${FIXTURE_PRODUCTS}" \
    LEON_BOOK_BUILD_TEST_CALLS="${FIXTURE_ROOT}/swift-calls" \
    LEON_BOOK_BUILD_CONFIGURATION=debug LEON_BOOK_BUILD_SYSTEM= \
    LEON_BOOK_BUILD_TEST_NATIVE_AVAILABLE=0 \
    /bin/zsh "${FIXTURE_MACOS_DIR}/scripts/build-app.sh"
[[ "$(cat "${PACKAGED_BUILD_SYSTEM}")" == default ]]
if grep -q -- '--build-system' "${FIXTURE_ROOT}/swift-calls"; then
    print -u2 -- 'FAIL: unavailable native engine was still requested.'
    exit 1
fi
print -- 'PASS: direct Debug build falls back when native is unavailable.'

# Both engines may compile simultaneously, but their final bundle copies must
# never overlap. A failed mkdir in the ditto guard makes this test fail.
for CONFIGURATION in debug release; do
    PATH="${FIXTURE_ROOT}/bin:$PATH" TMPDIR="${FIXTURE_ROOT}/tmp/" \
        LEON_BOOK_BUILD_TEST_PRODUCTS="${FIXTURE_PRODUCTS}" \
        LEON_BOOK_BUILD_TEST_CALLS="${FIXTURE_ROOT}/swift-calls" \
        LEON_BOOK_BUILD_CONFIGURATION="${CONFIGURATION}" LEON_BOOK_BUILD_SYSTEM= \
        LEON_BOOK_BUILD_TEST_INSTALL_GUARD="${FIXTURE_ROOT}/install-busy" \
        LEON_BOOK_BUILD_TEST_INSTALL_LOG="${FIXTURE_ROOT}/installs" \
        /bin/zsh "${FIXTURE_MACOS_DIR}/scripts/build-app.sh" > "${FIXTURE_ROOT}/${CONFIGURATION}.log" 2>&1 &
    if [[ "${CONFIGURATION}" == debug ]]; then
        DEBUG_PID=$!
    else
        RELEASE_PID=$!
    fi
done
wait "${DEBUG_PID}"
wait "${RELEASE_PID}"
[[ "$(grep -c '^install$' "${FIXTURE_ROOT}/installs")" == 2 ]]
[[ ! -e "${FIXTURE_ROOT}/install-busy" ]]
print -- 'PASS: parallel Debug and Release builds serialize only final installation.'
