// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "LeonBookMac",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "LeonBook", targets: ["LeonBookApp"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "LeonBook",
            dependencies: [
                "CSQLite",
            ],
            path: "Sources/LeonBook"
        ),
        .executableTarget(
            name: "LeonBookApp",
            dependencies: [
                "LeonBook",
            ],
            path: "Sources/LeonBookApp"
        ),
        .executableTarget(
            name: "LeonBookChecks",
            path: "Checks/LeonBookChecks"
        ),
        .executableTarget(
            name: "LeonBookStoreChecks",
            dependencies: [
                "LeonBook",
                "CSQLite",
            ],
            path: "Checks/LeonBookStoreChecks"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
