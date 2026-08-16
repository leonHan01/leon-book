// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "LeonBookMac",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "LeonBook", targets: ["LeonBook"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .executableTarget(
            name: "LeonBook",
            dependencies: [
                "CSQLite",
            ],
            path: "Sources/LeonBook"
        ),
        .executableTarget(
            name: "LeonBookChecks",
            path: "Checks/LeonBookChecks"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
