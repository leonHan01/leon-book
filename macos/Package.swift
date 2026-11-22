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
    dependencies: [.package(path: "Vendor/SwiftMath")],
    targets: [
        .target(
            name: "LeonChat",
            dependencies: [.product(name: "SwiftMath", package: "SwiftMath")],
            path: "Sources/LeonChat",
            resources: [.copy("Resources/MarkdownRuntime")]
        ),
        .executableTarget(name: "LeonChatMessageChecks", dependencies: ["LeonChat"], path: "Tests/LeonChatTests/MessageChecks"),
        .executableTarget(name: "LeonChatMarkdownChecks", dependencies: ["LeonChat"], path: "Tests/LeonChatTests/MarkdownChecks"),
        .executableTarget(name: "LeonChatMathChecks", dependencies: ["LeonChat"], path: "Tests/LeonChatTests/MathChecks"),
        .executableTarget(name: "LeonChatTableLayoutChecks", dependencies: ["LeonChat"], path: "Tests/LeonChatTests/TableLayoutChecks"),
        .executableTarget(name: "LeonChatRichMarkdownChecks", dependencies: ["LeonChat"], path: "Tests/LeonChatTests/RichMarkdownChecks", resources: [.copy("Fixtures")]),
        .executableTarget(name: "LeonChatImageChecks", dependencies: ["LeonChat"], path: "Tests/LeonChatTests/ImageChecks"),
        .executableTarget(name: "LeonChatComposerChecks", dependencies: ["LeonChat"], path: "Tests/LeonChatTests/ComposerChecks"),
        .executableTarget(name: "LeonChatArchiveChecks", dependencies: ["LeonChat"], path: "Tests/LeonChatTests/ArchiveChecks"),
        .executableTarget(name: "LeonChatArchiveFlowChecks", dependencies: ["LeonChat"], path: "Tests/LeonChatTests/ArchiveFlowChecks"),
        .executableTarget(name: "LeonChatSwitchingChecks", dependencies: ["LeonChat"], path: "Tests/LeonChatTests/SwitchingChecks"),
        .executableTarget(name: "LeonChatSearchChecks", dependencies: ["LeonChat"], path: "Tests/LeonChatTests/SearchChecks"),
        .executableTarget(name: "LeonChatContextMemoryChecks", dependencies: ["LeonChat"], path: "Tests/LeonChatTests/ContextMemoryChecks"),
        .executableTarget(name: "LeonChatIntegrationChecks", dependencies: ["LeonChat"], path: "Tests/LeonChatTests/IntegrationChecks"),
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
                "LeonChat",
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
                "LeonChat",
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
            dependencies: ["LeonBook", "LeonBookBackupModule", "LeonBookModuleKit", "LeonBookTodoModule"],
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
