# leon-book for macOS

[English](README.md) | [简体中文](README.zh-CN.md)

This directory contains the native macOS implementation of `leon-book`. It uses SwiftUI for its windows, menus, navigation, reading, writing, and settings interfaces. Article web embeds use the system WebKit view; the app does not launch Safari or Chrome.

Articles, drafts, settings, images, and videos are stored locally. SQLite is the source of truth for structured records; Markdown/JSON exports and media files remain on the local filesystem. The app does not start Node.js, an external browser, or a local HTTP service.

Article edits are written to a recovery snapshot after 3 seconds of inactivity. Continuous editing creates a history point every 5 minutes, retained for 30 days by default. Version history is available from both the reader and writing workspace, with side-by-side body diffs and restore-to-editor. Autosave never overwrites published content directly; the explicit Save Draft and Publish actions remain the formal save boundary.

## Search and quick navigation

The toolbar search button and `⌘⇧F` open unified full-text search across article titles, categories, tags, excerpts, bodies, and moment text. A SQLite FTS5 index follows saves, edits, trash moves, and restores automatically and produces contextual result snippets. Filters can be combined with `tag:`, `status:draft|published`, `type:article|moment`, `date:YYYY-MM-DD`, `after:YYYY-MM-DD`, and `before:YYYY-MM-DD`; quote phrases that contain spaces.

Press `⌘O` to search and open an article quickly. Press `⌘P` for the command palette, including navigation, new article, and library refresh actions.

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

The check script builds and runs native unit tests and checks without opening the app window. To generate an LLVM coverage report:

```bash
./scripts/leonblog coverage
```

The coverage script reports line, function, and region coverage for `Sources/LeonBook`.

## Article web embeds

Article Markdown can render remote HTTP(S) pages inline. Use either a dedicated `embed` fence:

```embed
https://example.com
```

or paste a standalone iframe snippet:

```html
<iframe src="https://example.com" title="Example" height="520"></iframe>
```

Only `http` and `https` URLs are accepted. The embedded view is interactive and includes a button to open the same page in the external browser.

## Article HTML components

Use the dedicated `html-render` fence to run HTML, CSS, and JavaScript directly in the article and its live editor preview:

````markdown
```html-render height=360
<div style="padding: 20px; background: #2563eb; color: white">
  <h2>Custom component</h2>
  <button onclick="this.textContent = 'Clicked'">Click</button>
</div>
```
````

`height` is optional and defaults to 360; accepted values are clamped to 160–1200. A regular `html` fence still displays source code without executing it. HTML components use an isolated ephemeral WebKit data store, and HTTP(S) links open in the external browser. Only run HTML and JavaScript you trust.

## Data directory

The app selects its data directory in this order:

1. `LEON_BOOK_WORKDIR`
2. `/Volumes/T7Shield/myblog/`

The default data directory is `/Volumes/T7Shield/myblog/`. If it is unavailable, the app asks for a work directory on first launch and remembers the choice. Set `LEON_BOOK_WORKDIR` to use another library.

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
