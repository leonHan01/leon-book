import Darwin
import Foundation
import Notebook36Core

var failures: [String] = []

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
    }
}

expect(
    AppConfiguration.normalizedSiteURL("localhost:3000")?.absoluteString == "http://localhost:3000",
    "localhost should default to HTTP"
)
expect(AppConfiguration.normalizedSiteURL("https://blog.example.com") == nil, "Remote sites should be rejected")
expect(
    AppConfiguration.normalizedSiteURL("javascript:alert(1)") == nil,
    "Unsafe URL schemes should be rejected"
)
expect(AppConfiguration.normalizedSiteURL("https://") == nil, "Incomplete URLs should be rejected")
expect(AppConfiguration.normalizedSiteURL("   ") == nil, "Blank URLs should be rejected")

if failures.isEmpty {
    print("Notebook36 checks passed")
} else {
    for failure in failures {
        fputs("Check failed: \(failure)\n", stderr)
    }
    exit(1)
}
