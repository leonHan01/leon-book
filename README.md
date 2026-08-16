# leon-book

[English](README.md) | [简体中文](README.zh-CN.md)

`leon-book` is a native macOS writing app for managing articles, drafts, images, videos, moments, and creative activity.

The app is built with SwiftUI and stores data directly on the local filesystem. It does not depend on a browser, Node.js service, or HTTP API.

## Features

- Read, edit, and publish articles
- Save drafts locally with independent workspaces for multiple users
- Manage image and video assets
- Publish image-and-text moments and browse the timeline
- View recent edits and yearly creative activity
- Work offline with full control over local data

## Requirements

- macOS 13 or later
- Swift 5.10 or later

Full Xcode is not required for local builds and checks.

## Commands

Run the following commands from the project root:

```bash
./scripts/leonblog open
```

`open` builds the app when it is missing or out of date, then opens `leon-book`. Other available commands are:

```bash
./scripts/leonblog start   # Alias for open
./scripts/leonblog build   # Build the macOS app
./scripts/leonblog test    # Run native checks
./scripts/leonblog help    # Show command help
```

The built app is located at:

```text
macos/dist/leon-book.app
```

## Local data

By default, data is stored at:

```text
~/Library/Application Support/leon-book/
├── users.json          # Local user registry
├── active-user.json    # Most recently used user
└── workspaces/
    └── <user-id>/      # Per-user workspace
        ├── articles/   # Article JSON, Markdown, and indexes
        ├── drafts/     # Draft recovery copies
        ├── media/      # Original image and video files
        ├── moments/    # Moment data and feed index
        └── activity/   # Creative activity records
```

The data directory is selected in this order:

1. `LEON_BOOK_WORKDIR`
2. `NOTEBOOK36_WORKDIR` (legacy compatibility)
3. `/Volumes/T7Shield/myblog` (when it exists)
4. `~/Library/Application Support/Notebook 36/` (legacy app-support directory, when it exists)
5. `~/Library/Application Support/leon-book/`

When the multi-user structure is initialized, existing articles, drafts, media, moments, and activity records in the root directory are automatically moved into the default `leon` workspace. Uninstalling the app does not remove local data; back up the directory like any other local files.

## Development

The native macOS source code, resources, and check scripts are located in [`macos/`](macos/). See [`macos/README.md`](macos/README.md) for additional build, debugging, and data-directory details.

To run the SwiftPM executable directly:

```bash
swift run --package-path macos Notebook36
```

## Design principles

`leon-book` prioritizes local availability, transparent data storage, and a responsive interface. Articles and media are stored as ordinary local files that users can manage with Finder, backup tools, or version control.
