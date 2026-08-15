// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Notebook36Mac",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "Notebook36", targets: ["Notebook36"]),
    ],
    targets: [
        .executableTarget(
            name: "Notebook36",
            path: "Sources/Notebook36"
        ),
        .executableTarget(
            name: "Notebook36Checks",
            path: "Checks/Notebook36Checks"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
