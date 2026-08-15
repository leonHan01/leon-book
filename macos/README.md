# leon-book for macOS

This directory contains the native macOS implementation of `leon-book`. It uses SwiftUI for its windows, menus, navigation, reading, writing, and settings interfaces. It does not use Safari, Chrome, or WKWebView.

Articles, drafts, settings, images, and videos are stored on the local filesystem. The app does not start Node.js, a browser, or a local HTTP service.

## Build and run

Requirements: macOS 13 or later and Swift 5.10 or later. From the project root, use the management script:

```bash
./scripts/leonblog build
./scripts/leonblog open
```

The built app is located at `macos/dist/leon-book.app` and uses ad-hoc signing for local use.

To run the SwiftPM executable directly:

```bash
swift run --package-path macos Notebook36
```

`Notebook36` is the current internal SwiftPM target name; the user-facing app name is `leon-book`.

## Checks

```bash
./scripts/leonblog test
```

The check script builds and runs native checks without opening the app window.

## Data directory

The app selects its data directory in this order:

1. `LEON_BOOK_WORKDIR`
2. `NOTEBOOK36_WORKDIR` (legacy compatibility)
3. `/Volumes/T7Shield/myblog` (when it exists)
4. `~/Library/Application Support/Notebook 36/` (legacy directory, when it exists)
5. `~/Library/Application Support/leon-book/`

The default user is `leon`. Each user has an isolated `workspaces/<user-id>` directory. When upgrading to the multi-user structure, existing articles, drafts, media, moments, and activity records in the root directory are automatically moved into the `leon` workspace.

If multiple macOS SDKs are installed, use `LEON_BOOK_SDK_PATH` to select the SDK for packaging. `NOTEBOOK36_SDK_PATH` remains supported for legacy configurations:

```bash
LEON_BOOK_SDK_PATH=/path/to/MacOSX.sdk ./scripts/leonblog build
```

## Directory structure

```text
macos/
├── Sources/Notebook36/      # SwiftUI app source
├── Checks/Notebook36Checks/  # Native checks
├── Resources/Info.plist     # App metadata
└── scripts/                 # Build and check scripts
```
