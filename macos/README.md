# leon-book for macOS

[English](README.md) | [简体中文](README.zh-CN.md)

This directory contains the native macOS implementation of `leon-book`. It uses SwiftUI for its windows, menus, navigation, reading, writing, and settings interfaces. It does not use Safari, Chrome, or WKWebView.

Articles, drafts, settings, images, and videos are stored locally. SQLite is the source of truth for structured records; Markdown/JSON exports and media files remain on the local filesystem. The app does not start Node.js, a browser, or a local HTTP service.

## Build and run

Requirements: macOS 13 or later and Swift 5.10 or later. From the project root, use the management script:

```bash
./scripts/leonblog build
./scripts/leonblog open
```

The built app is located at `macos/dist/leon-book.app` and uses ad-hoc signing for local use.

To run the SwiftPM executable directly:

```bash
swift run --package-path macos LeonBook
```

`LeonBook` is the internal SwiftPM target name; the user-facing app name is `leon-book`.

## Checks

```bash
./scripts/leonblog test
```

The check script builds and runs native checks without opening the app window.

## Data directory

The app selects its data directory in this order:

1. `LEON_BOOK_WORKDIR`
2. `/Volumes/T7Shield/myblog` (when it exists)
3. `~/Library/Application Support/leon-book/`

The default user is `leon`. Each user has an isolated `workspaces/<user-id>` directory. When upgrading to the multi-user structure, existing articles, drafts, media, moments, and activity records in the root directory are automatically moved into the `leon` workspace. Existing JSON records are imported into the workspace SQLite database on first launch.

If multiple macOS SDKs are installed, use `LEON_BOOK_SDK_PATH` to select the SDK for packaging:

```bash
LEON_BOOK_SDK_PATH=/path/to/MacOSX.sdk ./scripts/leonblog build
```

## Directory structure

```text
macos/
├── Sources/LeonBook/         # SwiftUI app source
├── Checks/LeonBookChecks/    # Native checks
├── Resources/Info.plist     # App metadata
└── scripts/                 # Build and check scripts
```
