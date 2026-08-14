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
    AppConfiguration.normalizedSiteURL("blog.example.com")?.absoluteString == "https://blog.example.com",
    "Hosted domains should default to HTTPS"
)
expect(
    AppConfiguration.normalizedSiteURL("localhost:3000")?.absoluteString == "http://localhost:3000",
    "localhost should default to HTTP"
)
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
