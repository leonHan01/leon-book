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
/Volumes/T7Shield/myblog/
├── leon-book.sqlite    # Primary SQLite database for users and settings
├── users.json          # Human-readable compatibility export
├── active-user.json    # Human-readable compatibility export
└── workspaces/
    └── <user-id>/      # Per-user workspace
        ├── leon-book.sqlite # Articles, moments, and activity records
        ├── articles/   # Article JSON, Markdown, and indexes
        ├── drafts/     # Draft recovery copies
        ├── media/      # Original image and video files
        ├── moments/    # Moment data and feed index
        └── activity/   # Creative activity records
```

The data directory is selected in this order:

1. `LEON_BOOK_WORKDIR`
2. `/Volumes/T7Shield/myblog/`

The default data directory is `/Volumes/T7Shield/myblog/`. If it is unavailable, the app asks you to choose a work directory on first launch and remembers your choice. To use another directory, set the environment variable before opening the app:

```bash
LEON_BOOK_WORKDIR=/Volumes/T7Shield/myblog ./scripts/leonblog open
```

When the multi-user structure is initialized, existing articles, drafts, media, moments, and activity records in the root directory are automatically moved into the default `leon` workspace. Uninstalling the app does not remove local data; back up the directory like any other local files.

SQLite is the source of truth for structured records. JSON and Markdown files are kept as readable local exports and for compatibility with existing workspaces; images and videos remain ordinary local files under `media/`. Existing JSON records are imported into SQLite automatically on first launch.

## Development

The native macOS source code, resources, and check scripts are located in [`macos/`](macos/). See [`macos/README.md`](macos/README.md) for additional build, debugging, and data-directory details.

To run the SwiftPM executable directly:

```bash
swift run --package-path macos LeonBook
```

## Design principles

`leon-book` prioritizes local availability, transparent data storage, and a responsive interface. Articles and media are stored as ordinary local files that users can manage with Finder, backup tools, or version control.
