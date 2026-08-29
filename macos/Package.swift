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
            name: "LeonBookModuleKit",
            path: "Sources/LeonBookModuleKit"
        ),
        .target(
            name: "LeonBookSearchModule",
            dependencies: ["LeonBookModuleKit"],
            path: "Sources/LeonBookSearchModule"
        ),
        .target(
            name: "LeonBookKnowledgeGraphModule",
            dependencies: ["LeonBookModuleKit"],
            path: "Sources/LeonBookKnowledgeGraphModule"
        ),
        .target(
            name: "LeonBookPublishingModule",
            dependencies: ["LeonBookModuleKit"],
            path: "Sources/LeonBookPublishingModule"
        ),
        .target(
            name: "LeonBookBackupModule",
            dependencies: ["LeonBookModuleKit"],
            path: "Sources/LeonBookBackupModule"
        ),
        .target(
            name: "LeonBookCaptureModule",
            dependencies: ["LeonBookModuleKit"],
            path: "Sources/LeonBookCaptureModule"
        ),
        .target(
            name: "LeonBook",
            dependencies: [
                "CSQLite",
                "LeonBookModuleKit",
                "LeonBookSearchModule",
                "LeonBookKnowledgeGraphModule",
                "LeonBookPublishingModule",
                "LeonBookBackupModule",
                "LeonBookCaptureModule",
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
        .executableTarget(
            name: "LeonBookTests",
            dependencies: [
                "LeonBook",
            ],
            path: "Tests/LeonBookTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .executableTarget(
            name: "LeonBookModuleTests",
            dependencies: [
                "LeonBookModuleKit",
                "LeonBookSearchModule",
                "LeonBookKnowledgeGraphModule",
                "LeonBookPublishingModule",
                "LeonBookBackupModule",
                "LeonBookCaptureModule",
            ],
            path: "Tests/LeonBookModuleTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
