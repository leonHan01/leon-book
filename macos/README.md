# leon-book for macOS

[English](README.md) | [简体中文](README.zh-CN.md)

This directory contains the native macOS implementation of `leon-book`. It uses SwiftUI for its windows, menus, navigation, reading, writing, and settings interfaces. Article web embeds use the system WebKit view; the app does not launch Safari or Chrome.

Articles, drafts, settings, images, and videos are stored locally. SQLite is the source of truth for structured records; Markdown/JSON exports and media files remain on the local filesystem. The app does not start Node.js, an external browser, or a local HTTP service.

Article edits are written to a recovery snapshot after 3 seconds of inactivity. Continuous editing creates a history point every 5 minutes, retained for 30 days by default. Version history is available from both the reader and writing workspace, with side-by-side body diffs and restore-to-editor. Autosave never overwrites published content directly; the explicit Save Draft and Publish actions remain the formal save boundary.

## Search and quick navigation

The toolbar search button and `⌘⇧F` open unified full-text search across article titles, categories, tags, typed properties, excerpts, bodies, and moment text. A SQLite FTS5 index follows saves, edits, property renames, trash moves, and restores automatically and produces contextual result snippets. Filters can be combined with `tag:`, `status:draft|published`, `[property:value]`, `type:article|moment`, `date:YYYY-MM-DD`, `after:YYYY-MM-DD`, and `before:YYYY-MM-DD`; brackets preserve spaces in property names and values.

Press `⌘O` to search and open an article quickly. Press `⌘P` for a fuzzy command palette with recent and pinned commands. **Settings → Commands & Hotkeys** records, removes, or restores per-command shortcuts. Menus, URL-scheme actions, and App Intents ultimately invoke the same command registry. Type `/` at the start of an editor line to insert headings, tasks, callouts, code, tables, links, embeds, or smart collections.

## Smart collections and bookmarks

Smart collections are saved virtual queries over the current user's SQLite workspace. Filtering and sorting compile into parameterized SQL, so only matching article summaries are decoded instead of loading every body into memory first. A collection can combine article status, category, tags, title or body text, YAML/Properties values, update or publish dates, word count, and page views with all/any logic. Up to three sort keys, one grouping field, and a list, table, or cards layout are stored with each collection. Selecting a collection never moves or duplicates an article.

Bookmarks are separate shortcuts in the sidebar. Articles, individual Markdown headings, full-text searches, and the global article graph can be added or removed from their source view and reopened directly.

## Article outline and links

The reader keeps an Article Inspector on the right, so the outline, backlinks, outgoing links, unlinked mentions, and one-hop local graph stay available without scrolling to the end of a long article. Hovering a related article or graph node previews its status, excerpt, tags, and update time; clicking opens it. Unlinked mentions ignore existing `[[wiki links]]`, inline and fenced code, and Markdown links; each source row can convert all safe occurrences to wiki links with conflict protection.

Wiki links resolve case-insensitively by title, stable slug, or a unique `aliases` Property. Clicking a missing target opens a prefilled new-article draft, while `[[note#heading]]` and `[[#heading]]` retain the heading destination and scroll to the matching section. Imported aliases also enter full-text search and the article-link graph.

At narrow reader widths the inspector collapses automatically. Use the Article Inspector button in the article header to open the same navigation tools in a separate panel.

## Reader tabs and history

The reader keeps an article tab strip with independent back and forward history for every tab. A normal wiki-link click continues in the current tab; hold `⌘` while clicking a body link, backlink, outgoing link, local-graph node, or article-list row to open a new tab. The Recent Articles menu also offers explicit current-tab and new-tab actions.

Pinning protects a tab from being replaced: opening another article automatically creates a new unpinned tab. Tabs, pin state, per-tab history, and the 20 most recent articles are remembered separately for each user. Use `⌘[` and `⌘]` to move backward and forward.

## Text-selection comments

The right side of the reader opens on the Comments pane. Drag across body text, or double-click a word, to quote the selection and focus the comment composer automatically. Clear the quote to leave a general article comment. Comments support replies and deletion; deleting a parent also deletes its replies.

An anchored comment stores both its source quote and nearest Markdown heading. Clicking the quote returns to that section, and the anchor is recalculated from the quote after article edits. Comments live in the current user's SQLite workspace and are included in local backups.

## Writing modes

The writing workspace offers four modes; the selection is saved with the active task layout:

- **Focus** uses the full-width inline preview editor and hides article settings and formatting hints.
- **Live Preview** styles headings, emphasis, code, quotes, lists, links, and wiki links directly inside the editable body while de-emphasizing Markdown markers.
- **Source** shows unrendered Markdown for precise syntax control.
- **Split** keeps source editing on the left and the complete rendered result, including images and embeds, on the right.

All four modes share the same body, autosave history, undo stack, image paste handling, and wiki-link suggestions, so changing layout does not discard editing state.
Use `⌘⌥1` through `⌘⌥4` to switch through the four modes in order.

The editor's right sidebar switches among Settings, Properties, Outline, and Links. Properties provides typed editors for text, lists, numbers, dates, checkboxes, and tags, preserves those types in SQLite/JSON, emits valid YAML, and can rename a key across every article without overwriting conflicting values. Outline follows body headings live, and Links combines live wiki links with saved backlinks and unlinked mentions. The selected pane and sidebar visibility are part of the saved layout.

## Task layouts and multiple windows

Writing, Reading, and Reviewing are three overwriteable task-layout presets. The layout menu saves the destination, editor mode, editor sidebar pane and visibility, plus the reader inspector pane and visibility; each preset can also be reset to its built-in default. Presets are stored per user, while every macOS window owns independent tabs, current article, and back/forward history. Menu commands target only the focused window.

## Page performance and module seams

Main navigation mounts only the selected page. It no longer prewarms and permanently retains complete SwiftUI/NSHostingView trees for the dashboard, library, graph, moments, editor, and settings. Only lightweight cross-page state is cached, including collapsed moment days, per-visit impression IDs, and graph filters and zoom; image decoders, video players, WebKit instances, and large lists can be released when their page closes.

Each article's wiki-link references and mention-search document update incrementally in the body-write transaction. Opening the relation inspector reads summaries, the current article's outgoing links, candidate backlinks, and FTS mention candidates only; opening the global graph reads the link index instead of reparsing every Markdown body. Existing workspaces backfill these derived indexes once on first open.

The global article graph supports title, slug, tag, and alias search; publication-status and orphan filters; a 50–500 node cap; and 50%–180% zoom. Before drawing, the projection module ranks matching nodes by degree, clips the result, and removes edges whose endpoints are no longer visible.

Source is split along Article, Editor, Article Properties, Backup, Import, Search, Graph Projection, and Navigation Page State seams. Views keep the existing `NativeAppModel` interface, while implementation and verification stay local to the corresponding module.

## Importing an Obsidian Vault

Choose a Vault under **Settings → Obsidian Vault Import**. The app performs a read-only scan first and previews importable notes, attachments, slug conflicts, and parsing warnings. It writes to the current user's workspace only after a second confirmation.

The importer handles common YAML Properties (including list properties and aliases), `[[note]]`, `[[note#heading|alias]]`, images, videos, and ordinary file attachments. Vault links are mapped to stable article slugs without discarding heading destinations, and attachments are copied into each article's `media/<slug>/` directory. Unmapped YAML properties are retained in SQLite and emitted in subsequent Markdown exports.

This is a one-way import, not two-way synchronization. The app never modifies, watches, or writes back to the Obsidian Vault; SQLite remains authoritative after import. If SQLite already contains the same slug, including a trashed article, the note is marked as a conflict and skipped by default to prevent either data source from overwriting the other.

## Automation and Shortcuts

The app registers the `leonbook` URL scheme for Raycast, browser bookmarks, shell launchers, and other local automation:

- `leonbook://new` opens a new article draft. Optional `title`, `content`, and `url` parameters prefill a browser clip; `name`, `text`, and `source` are accepted aliases.
- `leonbook://open?slug=my-article` opens an existing article by its stable slug.
- `leonbook://search?q=SQLite` opens global search and runs the query. An empty query opens the search sheet.
- `leonbook://today` opens Moments with the Today filter and clears other moment filters.

Percent-encode parameter values, especially spaces, `#`, `&`, `/`, and full source URLs. For example: `leonbook://new?title=Web%20clip&url=https%3A%2F%2Fexample.com`.

The same four actions are published through App Intents and appear under leon-book in the macOS Shortcuts app after the built app has been launched once. Intent deliveries are queued across cold launch until the selected workspace is ready, so an automation is not discarded while SQLite is opening.

## Local backups and recovery

Choose an independent destination under **Settings → Backups**. Changes are coalesced into at most one automatic snapshot per hour by default. Each snapshot is logically complete, while unchanged files use APFS copy-on-write clones where possible and otherwise reuse the preceding snapshot or fall back to copying.

The default policy retains 90 days and at most 60 snapshots while preserving 10 GB of free disk space. Settings exposes all policy values, storage estimates, Finder browsing, SHA-256 validation, and whole-library restore. A restore creates a safety snapshot first and atomically swaps a validated staged copy into place. The backup destination cannot be nested inside the live data directory, and the app never uploads backups automatically.

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
