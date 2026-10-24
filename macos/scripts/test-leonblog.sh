#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp/}leonblog-restart.XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT
PROJECT="$FIXTURE_ROOT/project with spaces"
APP="$PROJECT/macos/dist/leon-book.app/Contents"
export LEONBLOG_TEST_EVENTS="$FIXTURE_ROOT/events"
export LEONBLOG_TEST_RUNNING="$FIXTURE_ROOT/running"
mkdir -p "$PROJECT/scripts" "$PROJECT/macos/scripts" "$FIXTURE_ROOT/bin"
cp "$SCRIPT_DIR/../../scripts/leonblog" "$PROJECT/scripts/leonblog"

# Run the real CLI dispatch and freshness check without Swift or an app window.
cat > "$PROJECT/macos/scripts/build-app.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'build:%s:%s\n' "${LEON_BOOK_BUILD_CONFIGURATION:-missing}" "${LEON_BOOK_BUILD_SYSTEM:-missing}" >> "$LEONBLOG_TEST_EVENTS"
[[ "${LEONBLOG_TEST_BUILD_FAIL:-0}" != 1 ]] || exit 1
EOF
cat > "$FIXTURE_ROOT/bin/pgrep" <<'EOF'
#!/bin/sh
test -f "$LEONBLOG_TEST_RUNNING"
EOF
cat > "$FIXTURE_ROOT/bin/osascript" <<'EOF'
#!/bin/sh
printf 'quit\n' >> "$LEONBLOG_TEST_EVENTS"
test "${LEONBLOG_TEST_QUIT_FAIL:-0}" != 1 || exit 1
rm -f "$LEONBLOG_TEST_RUNNING"
EOF
cat > "$FIXTURE_ROOT/bin/open" <<'EOF'
#!/bin/sh
printf 'open\n' >> "$LEONBLOG_TEST_EVENTS"
EOF
cat > "$FIXTURE_ROOT/bin/swift" <<'EOF'
#!/bin/sh
if [ "${LEONBLOG_TEST_NATIVE_AVAILABLE:-1}" = 1 ]; then
  printf '        native - Native Build System\n'
fi
printf '        swiftbuild - Swift Build engine\n'
EOF
chmod +x "$PROJECT/macos/scripts/build-app.sh" "$FIXTURE_ROOT/bin/"*
export PATH="$FIXTURE_ROOT/bin:$PATH"
unset LEON_BOOK_BUILD_CONFIGURATION LEON_BOOK_BUILD_SYSTEM

reset_fixture() {
  rm -rf "$PROJECT/macos/Sources" "$PROJECT/macos/Resources" "$PROJECT/macos/dist"
  mkdir -p "$PROJECT/macos/Sources/LeonBook" "$PROJECT/macos/Resources" \
    "$APP/MacOS" "$APP/Resources/LeonBookMac_LeonBook.bundle"
  touch "$PROJECT/macos/Package.swift" "$PROJECT/macos/Sources/LeonBook/Example.swift" \
    "$PROJECT/macos/Resources/Info.plist" "$PROJECT/macos/scripts/swift-sdk.sh"
  find "$PROJECT/macos" -exec touch -t 202001010000 {} +
  touch -t 202001020000 "$APP/MacOS/LeonBook" "$APP/MacOS/LeonBookCLI"
  chmod +x "$APP/MacOS/LeonBook" "$APP/MacOS/LeonBookCLI"
  printf 'debug\n' > "$APP/Resources/leonbook-build-configuration"
  printf 'native\n' > "$APP/Resources/leonbook-build-system"
  touch -t 202001020000 "$APP/Resources/leonbook-build-configuration"
  : > "$LEONBLOG_TEST_EVENTS"
  : > "$LEONBLOG_TEST_RUNNING"
  unset LEONBLOG_TEST_BUILD_FAIL LEONBLOG_TEST_QUIT_FAIL
  export LEONBLOG_TEST_NATIVE_AVAILABLE=1
}

assert_events() {
  local expected="$1" actual
  actual="$(cat "$LEONBLOG_TEST_EVENTS")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\nExpected:\n%s\nActual:\n%s\n' "$2" "$expected" "$actual" >&2
    exit 1
  fi
  printf 'PASS: %s\n' "$2"
}

reset_fixture
bash "$PROJECT/scripts/leonblog" restart > "$FIXTURE_ROOT/output"
assert_events $'quit\nopen' 'unchanged restart skips all compilation and packaging'

reset_fixture
touch -t 202001030000 "$PROJECT/macos/Sources/LeonBook/Example.swift"
bash "$PROJECT/scripts/leonblog" restart > "$FIXTURE_ROOT/output"
assert_events $'quit\nbuild:debug:native\nopen' 'changed Swift source rebuilds before launching'

reset_fixture
rm "$PROJECT/macos/Sources/LeonBook/Example.swift"
bash "$PROJECT/scripts/leonblog" restart > "$FIXTURE_ROOT/output"
assert_events $'quit\nbuild:debug:native\nopen' 'deleted source triggers a rebuild'

reset_fixture
touch -t 202001030000 "$PROJECT/macos/Resources/Info.plist"
bash "$PROJECT/scripts/leonblog" restart > "$FIXTURE_ROOT/output"
assert_events $'quit\nbuild:debug:native\nopen' 'changed app resources trigger a rebuild'

reset_fixture
rm "$APP/MacOS/LeonBookCLI"
bash "$PROJECT/scripts/leonblog" restart > "$FIXTURE_ROOT/output"
assert_events $'quit\nbuild:debug:native\nopen' 'missing packaged CLI triggers a rebuild'

reset_fixture
rm "$APP/MacOS/LeonBook"
bash "$PROJECT/scripts/leonblog" restart > "$FIXTURE_ROOT/output"
assert_events $'quit\nbuild:debug:native\nopen' 'missing app triggers a rebuild'

reset_fixture
rm "$LEONBLOG_TEST_RUNNING"
bash "$PROJECT/scripts/leonblog" restart > "$FIXTURE_ROOT/output"
assert_events 'open' 'stopped, current app launches without rebuilding'

reset_fixture
touch -t 202001030000 "$PROJECT/macos/Package.swift"
export LEONBLOG_TEST_BUILD_FAIL=1
if bash "$PROJECT/scripts/leonblog" restart > "$FIXTURE_ROOT/output" 2>&1; then
  printf 'FAIL: restart succeeded after a build failure\n' >&2
  exit 1
fi
assert_events $'quit\nbuild:debug:native' 'failed build prevents launching an outdated app'

reset_fixture
export LEONBLOG_TEST_QUIT_FAIL=1
if bash "$PROJECT/scripts/leonblog" restart > "$FIXTURE_ROOT/output" 2>&1; then
  printf 'FAIL: restart succeeded after a quit failure\n' >&2
  exit 1
fi
assert_events 'quit' 'quit failure prevents rebuilding or launching'

reset_fixture
bash "$PROJECT/scripts/leonblog" build > "$FIXTURE_ROOT/output"
assert_events 'build:release:default' 'explicit build always invokes the builder'

reset_fixture
printf 'release\n' > "$APP/Resources/leonbook-build-configuration"
printf 'default\n' > "$APP/Resources/leonbook-build-system"
bash "$PROJECT/scripts/leonblog" restart > "$FIXTURE_ROOT/output"
assert_events $'quit\nbuild:debug:native\nopen' 'restart switches a Release app to Debug for development'

reset_fixture
bash "$PROJECT/scripts/leonblog" restart --release > "$FIXTURE_ROOT/output"
assert_events $'quit\nbuild:release:default\nopen' 'restart --release selects an optimized build'

reset_fixture
printf 'release\n' > "$APP/Resources/leonbook-build-configuration"
printf 'default\n' > "$APP/Resources/leonbook-build-system"
touch -t 202001020000 "$APP/Resources/leonbook-build-configuration"
bash "$PROJECT/scripts/leonblog" restart --release > "$FIXTURE_ROOT/output"
assert_events $'quit\nopen' 'unchanged Release app also skips a rebuild'

reset_fixture
rm "$APP/Resources/leonbook-build-configuration"
bash "$PROJECT/scripts/leonblog" restart > "$FIXTURE_ROOT/output"
assert_events $'quit\nbuild:debug:native\nopen' 'legacy app without build metadata is rebuilt once'

reset_fixture
if bash "$PROJECT/scripts/leonblog" restart --typo > "$FIXTURE_ROOT/output" 2>&1; then
  printf 'FAIL: restart accepted an unknown option\n' >&2
  exit 1
fi
assert_events '' 'invalid option fails before quitting the app'

reset_fixture
printf 'release\n' > "$APP/Resources/leonbook-build-configuration"
printf 'default\n' > "$APP/Resources/leonbook-build-system"
touch -t 202001020000 "$APP/Resources/leonbook-build-configuration"
bash "$PROJECT/scripts/leonblog" open > "$FIXTURE_ROOT/output"
assert_events 'open' 'open reuses an existing Release build without switching modes'

reset_fixture
bash "$PROJECT/scripts/leonblog" build --debug > "$FIXTURE_ROOT/output"
assert_events 'build:debug:native' 'explicit build --debug selects development compilation'

reset_fixture
export LEON_BOOK_BUILD_CONFIGURATION=release
bash "$PROJECT/scripts/leonblog" restart > "$FIXTURE_ROOT/output"
assert_events $'quit\nbuild:release:default\nopen' 'environment can override the default restart configuration'
unset LEON_BOOK_BUILD_CONFIGURATION LEON_BOOK_BUILD_SYSTEM

reset_fixture
export LEON_BOOK_BUILD_SYSTEM=swiftbuild
bash "$PROJECT/scripts/leonblog" restart > "$FIXTURE_ROOT/output"
assert_events $'quit\nbuild:debug:swiftbuild\nopen' 'engine override rebuilds instead of reusing a different engine'
unset LEON_BOOK_BUILD_SYSTEM

reset_fixture
printf 'swiftbuild\n' > "$APP/Resources/leonbook-build-system"
bash "$PROJECT/scripts/leonblog" open > "$FIXTURE_ROOT/output"
assert_events 'open' 'open retains an explicitly selected installed engine'

reset_fixture
export LEON_BOOK_BUILD_SYSTEM=invalid
if bash "$PROJECT/scripts/leonblog" restart > "$FIXTURE_ROOT/output" 2>&1; then
  printf 'FAIL: restart accepted an unknown build engine\n' >&2
  exit 1
fi
assert_events '' 'invalid engine fails before quitting the app'
unset LEON_BOOK_BUILD_SYSTEM

reset_fixture
rm "$APP/Resources/leonbook-build-system"
bash "$PROJECT/scripts/leonblog" restart > "$FIXTURE_ROOT/output"
assert_events $'quit\nbuild:debug:native\nopen' 'missing engine metadata triggers a one-time rebuild'

reset_fixture
export LEONBLOG_TEST_NATIVE_AVAILABLE=0
bash "$PROJECT/scripts/leonblog" restart > "$FIXTURE_ROOT/output"
assert_events $'quit\nbuild:debug:default\nopen' 'future toolchain without native falls back to its default engine'
