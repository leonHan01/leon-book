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
        .target(
            name: "Notebook36Core",
            path: "Sources/Notebook36Core"
        ),
        .executableTarget(
            name: "Notebook36",
            dependencies: ["Notebook36Core"],
            path: "Sources/Notebook36"
        ),
        .executableTarget(
            name: "Notebook36Checks",
            dependencies: ["Notebook36Core"],
            path: "Checks/Notebook36Checks"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
