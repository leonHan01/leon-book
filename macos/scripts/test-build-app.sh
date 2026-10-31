#!/bin/zsh

set -euo pipefail
unsetopt BG_NICE

SCRIPT_DIR="${0:A:h}"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp/}leon-book-packaging.XXXXXX")"
trap 'rm -rf "${FIXTURE_ROOT}"' EXIT
FIXTURE_MACOS_DIR="${FIXTURE_ROOT}/project with spaces/macos"
FIXTURE_PRODUCTS="${FIXTURE_ROOT}/products"
export LEON_BOOK_BUILD_CACHE_DIR="${FIXTURE_ROOT}/persistent cache"
unset LEON_BOOK_FORCE_SWIFT_BUILD
MACOS_DIR="${FIXTURE_MACOS_DIR}"
source "${SCRIPT_DIR}/swift-cache.sh"
DEFAULT_CACHE="$(leonbook_build_root default)"
NATIVE_CACHE="$(leonbook_build_root native)"

# Exercise the real packaging steps with tiny executables, without compiling
# Swift or opening an application window.
mkdir -p "${FIXTURE_MACOS_DIR}/scripts" "${FIXTURE_MACOS_DIR}/Resources" \
    "${FIXTURE_MACOS_DIR}/Sources/LeonBook/Resources/en.lproj" \
    "${FIXTURE_PRODUCTS}/LeonBookMac_LeonBook.bundle" \
    "${FIXTURE_ROOT}/bin" "${FIXTURE_ROOT}/tmp"
cp "${SCRIPT_DIR}/build-app.sh" "${FIXTURE_MACOS_DIR}/scripts/build-app.sh"
cp "${SCRIPT_DIR}/build-state.py" "${SCRIPT_DIR}/swift-cache.sh" "${FIXTURE_MACOS_DIR}/scripts/"
print -r -- 'SDK_ARGUMENTS=()' > "${FIXTURE_MACOS_DIR}/scripts/swift-sdk.sh"
touch "${FIXTURE_MACOS_DIR}/Resources/Info.plist" "${FIXTURE_MACOS_DIR}/Resources/Notes.icns" "${FIXTURE_MACOS_DIR}/Package.swift"
EDITOR_JS="${FIXTURE_MACOS_DIR}/Sources/LeonBook/Resources/RichArticleColumns.js"
EDITOR_CSS="${FIXTURE_MACOS_DIR}/Sources/LeonBook/Resources/RichArticleColumns.css"
print -- '// initial script' > "${EDITOR_JS}"
print -- '/* initial style */' > "${EDITOR_CSS}"

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
    printf '// edit during compilation\n' >> "$LEON_BOOK_BUILD_TEST_EDIT"
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
printf '%s\n' "$*" >> "${LEON_BOOK_BUILD_TEST_CALLS}.signing"
if [ "${LEON_BOOK_BUILD_TEST_SIGN_FAIL:-0}" = 1 ] && [ "$1" = --force ]; then
    exit 1
fi
if [ -n "${LEON_BOOK_BUILD_TEST_SIGN_EDIT:-}" ] && [ "$1" = --force ]; then
    printf '// edit during signing\n' >> "$LEON_BOOK_BUILD_TEST_SIGN_EDIT"
fi
exit 0
EOF
cat > "${FIXTURE_ROOT}/bin/ditto" <<'EOF'
#!/bin/sh
set -eu
if [ "${LEON_BOOK_BUILD_TEST_COPY_FAIL:-0}" = 1 ]; then
    exit 1
fi
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
grep -Fq -- "--scratch-path ${DEFAULT_CACHE}/scratch" "${FIXTURE_ROOT}/swift-calls"
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
grep -Fq -- "--scratch-path ${NATIVE_CACHE}/scratch" "${FIXTURE_ROOT}/swift-calls"
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
[[ -z "$(find "${LEON_BOOK_BUILD_CACHE_DIR}" -type d -name 'staging.*' -print)" ]]
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

run_builder() {
    PATH="${FIXTURE_ROOT}/bin:$PATH" TMPDIR="${FIXTURE_ROOT}/tmp/" \
        LEON_BOOK_BUILD_TEST_PRODUCTS="${FIXTURE_PRODUCTS}" \
        LEON_BOOK_BUILD_TEST_CALLS="${FIXTURE_ROOT}/swift-calls" \
        LEON_BOOK_BUILD_CONFIGURATION=debug LEON_BOOK_BUILD_SYSTEM=native \
        /bin/zsh "${FIXTURE_MACOS_DIR}/scripts/build-app.sh" > "${FIXTURE_ROOT}/resource-build.log" 2>&1
}
input_status() {
    python3 "${FIXTURE_MACOS_DIR}/scripts/build-state.py" status "${FIXTURE_MACOS_DIR}" \
        "${FIXTURE_MACOS_DIR}/dist/leon-book.app" debug native
}
run_builder
[[ "$(input_status)" == unchanged ]]
EXECUTABLE_HASHES="$(shasum -a 256 "${PACKAGED_MACOS_DIR}/"*)"
print -- '// script update' >> "${EDITOR_JS}"
print -- '/* style update */' >> "${EDITOR_CSS}"
: > "${FIXTURE_ROOT}/swift-calls"
: > "${FIXTURE_ROOT}/swift-calls.signing"
run_builder
[[ ! -s "${FIXTURE_ROOT}/swift-calls" ]]
grep -q '^--force ' "${FIXTURE_ROOT}/swift-calls.signing"
[[ "$(shasum -a 256 "${PACKAGED_MACOS_DIR}/"*)" == "${EXECUTABLE_HASHES}" ]]
PACKAGED_RESOURCES="${PACKAGED_BUILD_INFO:h}/LeonBookMac_LeonBook.bundle"
cmp "${EDITOR_JS}" "${PACKAGED_RESOURCES}/${EDITOR_JS:t}"
cmp "${EDITOR_CSS}" "${PACKAGED_RESOURCES}/${EDITOR_CSS:t}"
[[ "$(input_status)" == unchanged ]]
print -- 'PASS: editor JS/CSS update and re-sign without Swift or executable changes.'

cp -p "${EDITOR_JS}" "${FIXTURE_ROOT}/old-timestamp"
print -- '// same timestamp, different content' >> "${EDITOR_JS}"
touch -r "${FIXTURE_ROOT}/old-timestamp" "${EDITOR_JS}"
[[ "$(input_status)" == resources ]]
NEW_ASSET="${EDITOR_JS:h}/RichArticleExtra.js"
print -- '// newly added resource' > "${NEW_ASSET}"
rm "${EDITOR_CSS}"
run_builder
[[ ! -s "${FIXTURE_ROOT}/swift-calls" ]]
[[ ! -f "${PACKAGED_RESOURCES}/${EDITOR_CSS:t}" ]]
cmp "${NEW_ASSET}" "${PACKAGED_RESOURCES}/${NEW_ASSET:t}"
[[ "$(input_status)" == unchanged ]]
print -- 'PASS: resource additions/deletions and unchanged timestamps are detected.'

print -- '// needs signing' >> "${EDITOR_JS}"
PREVIOUS_STATE="$(cat "${PACKAGED_BUILD_INFO:h}/leonbook-build-inputs.json")"
if LEON_BOOK_BUILD_TEST_SIGN_FAIL=1 run_builder; then
    print -u2 -- 'FAIL: resource update ignored a signing failure.'; exit 1
fi
[[ ! -s "${FIXTURE_ROOT}/swift-calls" ]]
[[ "$(cat "${PACKAGED_BUILD_INFO:h}/leonbook-build-inputs.json")" == "${PREVIOUS_STATE}" ]]
[[ "$(input_status)" == resources ]]
print -- 'PASS: failed resource signing preserves the installed app and pending changes.'

if LEON_BOOK_BUILD_TEST_COPY_FAIL=1 run_builder; then
    print -u2 -- 'FAIL: resource update ignored an installation copy failure.'; exit 1
fi
[[ "$(cat "${PACKAGED_BUILD_INFO:h}/leonbook-build-inputs.json")" == "${PREVIOUS_STATE}" ]]
[[ "$(input_status)" == resources ]]
[[ -z "$(find "${FIXTURE_MACOS_DIR}/dist" -name '.leonbook-install.*' -print)" ]]
print -- 'PASS: failed installation copy preserves the existing app and cleans staging.'

LEON_BOOK_BUILD_TEST_SIGN_EDIT="${EDITOR_JS}" run_builder
[[ "$(input_status)" == resources ]]
run_builder
[[ "$(input_status)" == unchanged ]]
print -- 'PASS: edits made during resource signing remain pending for the next update.'

print -- '// native source change' >> "${EDITED_SOURCE}"
touch -t 202001010000 "${EDITED_SOURCE}"
: > "${FIXTURE_ROOT}/swift-calls"
run_builder
[[ "$(wc -l < "${FIXTURE_ROOT}/swift-calls" | tr -d ' ')" == 3 ]]
[[ "$(input_status)" == unchanged ]]
rm "${EDITED_SOURCE}"
[[ "$(input_status)" == build ]]
run_builder
print -- 'PASS: changed/deleted Swift sources always take the compilation path.'

print -- '// forced resource compilation' >> "${EDITOR_JS}"
: > "${FIXTURE_ROOT}/swift-calls"
LEON_BOOK_FORCE_SWIFT_BUILD=1 run_builder
[[ "$(wc -l < "${FIXTURE_ROOT}/swift-calls" | tr -d ' ')" == 3 ]]
rm "${PACKAGED_BUILD_INFO:h}/leonbook-build-inputs.json"
[[ "$(input_status)" == build ]]
run_builder
print -- 'PASS: explicit builds and legacy apps establish a full-build baseline.'

OLD_CACHE="$(leonbook_build_root native)"
[[ "$(TMPDIR=/different/temporary/directory leonbook_build_root native)" == "${OLD_CACHE}" ]]
[[ "$(leonbook_build_root tests)" != "${OLD_CACHE}" ]]
MACOS_DIR="${FIXTURE_MACOS_DIR}-other-checkout"
[[ "$(leonbook_build_root native)" != "${OLD_CACHE}" ]]
print -- 'PASS: cache paths survive TMPDIR changes and isolate checkouts, engines and tests.'
