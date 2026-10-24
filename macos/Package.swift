// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "LeonBookMac",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "LeonBook", targets: ["LeonBookApp"]),
        .executable(name: "LeonBookCLI", targets: ["LeonBookCLI"]),
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
            name: "LeonBookExtensionKit",
            dependencies: ["LeonBookModuleKit"],
            path: "Sources/LeonBookExtensionKit"
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
            name: "LeonBookTodoModule",
            dependencies: ["LeonBookModuleKit"],
            path: "Sources/LeonBookTodoModule"
        ),
        .target(
            name: "LeonBook",
            dependencies: [
                "CSQLite",
                "LeonBookExtensionKit",
                "LeonBookModuleKit",
                "LeonBookSearchModule",
                "LeonBookKnowledgeGraphModule",
                "LeonBookPublishingModule",
                "LeonBookBackupModule",
                "LeonBookCaptureModule",
                "LeonBookTodoModule",
            ],
            path: "Sources/LeonBook",
            resources: [
                .process("Resources"),
                .copy("Whiteboard"),
            ]
        ),
        .executableTarget(
            name: "LeonBookCLI",
            dependencies: ["LeonBook"],
            path: "Sources/LeonBookCLI"
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
                "LeonBookExtensionKit",
                "LeonBookTodoModule",
            ],
            path: "Tests/LeonBookTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .executableTarget(
            name: "LeonBookAutomationTests",
            dependencies: ["LeonBook", "LeonBookTodoModule"],
            path: "Tests/LeonBookAutomationTests"
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
                "LeonBookTodoModule",
            ],
            path: "Tests/LeonBookModuleTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
