#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
MACOS_DIR="${SCRIPT_DIR:h}"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp/}leon-book-resources.XXXXXX")"
trap 'rm -rf "${FIXTURE_ROOT}"' EXIT
APP="${FIXTURE_ROOT}/Resource Probe.app"
RESOURCES="${APP}/Contents/Resources/LeonBookMac_LeonBook.bundle"
mkdir -p "${APP}/Contents/MacOS" "${RESOURCES}"
cat > "${APP}/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ResourceProbe</string>
<key>CFBundleIdentifier</key><string>com.leon-book.resource-probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
print -r -- 'packaged resource' > "${RESOURCES}/Probe.txt"
cat > "${FIXTURE_ROOT}/main.swift" <<'EOF'
import Foundation

// The build cache is deliberately unavailable. The real app resource resolver
// must find Contents/Resources without reaching SwiftPM's cache accessor.
extension Bundle {
    static var module: Bundle { fatalError("Unexpected access to the SwiftPM build cache") }
}

@main
enum ResourceProbe {
    static func main() throws {
        guard let file = Bundle.leonBookResources.url(forResource: "Probe", withExtension: "txt"),
              file.path.hasPrefix(Bundle.main.bundleURL.path + "/Contents/Resources/") else {
            throw NSError(domain: "PackagedResourceMissing", code: 1)
        }
        print(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
EOF
MODULE_CACHE="${TMPDIR%/}/leon-book-resource-probe-modules"
mkdir -p "${MODULE_CACHE}"
export CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}"
source "${SCRIPT_DIR}/swift-sdk.sh"
swiftc -parse-as-library -sdk "${SDK_ARGUMENTS[2]}" \
    "${MACOS_DIR}/Sources/LeonBook/NativeResourceBundle.swift" "${FIXTURE_ROOT}/main.swift" \
    -o "${APP}/Contents/MacOS/ResourceProbe"

# Invoke only this tiny Foundation probe, without launching an app window.
[[ "$("${APP}/Contents/MacOS/ResourceProbe")" == 'packaged resource' ]]
print -- 'PASS: packaged resources load without access to the SwiftPM build cache.'
