# leon-book

[English](README.md) | [简体中文](README.zh-CN.md)

`leon-book` is a native macOS writing app for managing articles, drafts, images, videos, moments, and creative activity.

The app is built with SwiftUI and stores data directly on the local filesystem. It does not depend on an external browser, Node.js service, or HTTP API.

## Features

- Read, edit, and publish articles
- Automatically save recovery snapshots after 3 seconds of inactivity, with version diffs and restore
- Search articles, typed properties, excerpts, bodies, and moments with SQLite FTS5, `[property:value]` filters, `⌘O` quick open, and a `⌘P` command palette with fuzzy matching, recents, pins, and configurable hotkeys
- Save smart collections that SQLite filters and sorts directly, combining status, category, property, date, and numeric conditions with multi-sort, grouping, and list, table, or card layouts
- Bookmark articles, headings, searches, and the global graph as shortcuts in the sidebar
- Use the reader's right inspector for the outline, backlinks, outgoing links, convertible unlinked mentions, a local graph, and hover previews
- Filter, zoom, and degree-clip the global graph before rendering large workspaces
- Incrementally update link and mention indexes when a body changes; the inspector queries only the current article's candidate relations, while the global graph reuses indexed edges instead of rescanning every body
- Follow `[[wiki links]]` by title, slug, or alias; create missing targets from a click and jump through `[[note#heading]]` links
- Automate new articles, article opening, search, and today's moments through `leonbook://` URLs or macOS Shortcuts/App Intents
- Navigate with per-tab back/forward history, recent articles, pinned tabs, and `⌘-click` to open a new tab
- Comment on a dragged or double-clicked text selection, with quotes and replies collected in the right sidebar
- Edit text, list, number, date, checkbox, and tag properties; rename a property across the workspace; switch among Settings, Properties, Outline, and Links; and save per-user Writing, Reading, and Reviewing layouts
- Keep the current article, tabs, and back/forward navigation independent in every macOS window
- Mount only the selected main page and retain lightweight page state instead of prewarming full view trees
- Enable or disable Search, Knowledge Graph, Publishing, Backup, and Capture independently; their commands, events, and permissions share one ModuleKit contract
- Use any Markdown folder or Obsidian Vault as a workspace with copy import, read-only mount, or direct-edit modes
- Embed remote HTTP(S) webpages directly in article bodies
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

### Configure a separate backup location

Choose a different disk or independent directory under **Settings → Backups**. Data changes are coalesced and, by default, produce at most one timestamped, logically complete snapshot per hour. Unchanged files use APFS copy-on-write clones when available and otherwise reuse the preceding snapshot or fall back to copying, so large media is not blindly duplicated after every change.

The default policy retains snapshots for 90 days, caps the set at 60 snapshots, and preserves at least 10 GB of free space; all values are configurable. Settings shows the source size, estimated additional storage, and available capacity. You can browse snapshots in Finder, verify version 2 snapshots with SHA-256, or restore the entire data directory. Restore first creates a safety snapshot of the current workspace, then swaps a staged copy into place atomically and rolls back on failure.

The backup destination cannot be inside the live data directory. Backups remain local, unencrypted files and are never uploaded automatically; use a FileVault-protected APFS volume, encrypted external disk, or access-controlled folder for sensitive content.

Markdown is authoritative for articles, while SQLite keeps rebuildable article indexes plus comments, revisions, bookmarks, and other structured records. Images and videos remain ordinary local files under `media/`. Existing JSON records are imported automatically on first launch.

Settings offers three Markdown workspace modes. **Copy import** reads the selected folder and copies confirmed notes and attachments into the current user workspace. **Read-only mount** uses and watches the original folder while rejecting all article writes. **Direct edit** uses the same live mount but atomically writes saves, moves, and deletes back to the original Markdown files. SQLite, comments, revisions, layout state, and app-managed media stay inside the LeonBook user workspace; external mounted folders must be backed up separately.

## Development

The native macOS source code, resources, and check scripts are located in [`macos/`](macos/). See [`macos/README.md`](macos/README.md) for additional build, debugging, and data-directory details.

The Swift package uses `LeonBookModuleKit` as the first-party feature seam and gives Search, Knowledge Graph, Publishing, Backup, and Capture their own targets. Each module declares a stable ID, permissions, complete command metadata, and event names. The `LeonBook` target retains the SwiftUI, SQLite, and filesystem adapters, native command handlers, and persisted enablement. Disabling a module removes its commands and applies the same authorization gate to direct UI actions; destructive backup restores and capture writes must drain before disablement, while read-only scans are cancelled safely. Search/graph SQLite adapters and schema setup are also split out of the core `LocalBlogStore` file.

To run the SwiftPM executable directly:

```bash
swift run --package-path macos LeonBook
```

## Design principles

`leon-book` prioritizes local availability, transparent data storage, and a responsive interface. Articles and media are stored as ordinary local files that users can manage with Finder, backup tools, or version control.
