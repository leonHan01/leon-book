#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
MACOS_DIR="${SCRIPT_DIR:h}"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp/}leon-book-resources.XXXXXX")"
trap 'rm -rf "${FIXTURE_ROOT}"' EXIT
APP="${FIXTURE_ROOT}/Resource Probe.app"
RESOURCES="${APP}/Contents/Resources/LeonBookMac_LeonBook.bundle"
mkdir -p "${APP}/Contents/MacOS" "${RESOURCES}"
CHAT_RESOURCES="${APP}/Contents/Resources/LeonBookMac_LeonChat.bundle"
MATH_RESOURCES="${APP}/Contents/Resources/SwiftMath_SwiftMath.bundle"
mkdir -p "${CHAT_RESOURCES}" "${MATH_RESOURCES}"
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
print -r -- 'packaged chat' > "${CHAT_RESOURCES}/Probe.txt"
print -r -- 'packaged math' > "${MATH_RESOURCES}/Probe.txt"
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
        guard let chat = ChatResources.bundle.url(forResource: "Probe", withExtension: "txt"),
              let math = MathResources.bundle.url(forResource: "Probe", withExtension: "txt"),
              chat.path.hasPrefix(Bundle.main.resourceURL!.path),
              math.path.hasPrefix(Bundle.main.resourceURL!.path),
              try String(contentsOf: chat, encoding: .utf8).hasPrefix("packaged chat"),
              try String(contentsOf: math, encoding: .utf8).hasPrefix("packaged math") else {
            throw NSError(domain: "PackagedChatResourcesMissing", code: 2)
        }
        print(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
EOF
source "${SCRIPT_DIR}/swift-cache.sh"
MODULE_CACHE="$(leonbook_build_root resource-probe)/modules"
mkdir -p "${MODULE_CACHE}"
export CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}"
source "${SCRIPT_DIR}/swift-sdk.sh"
swiftc -parse-as-library -sdk "${SDK_ARGUMENTS[2]}" \
    "${MACOS_DIR}/Sources/LeonBook/NativeResourceBundle.swift" "${FIXTURE_ROOT}/main.swift" \
    "${MACOS_DIR}/Sources/LeonChat/ChatResources.swift" \
    "${MACOS_DIR}/Vendor/SwiftMath/Sources/SwiftMath/MathResources.swift" \
    -o "${APP}/Contents/MacOS/ResourceProbe"

# Invoke only this tiny Foundation probe, without launching an app window.
[[ "$("${APP}/Contents/MacOS/ResourceProbe")" == 'packaged resource' ]]
print -- 'PASS: packaged resources load without access to the SwiftPM build cache.'
