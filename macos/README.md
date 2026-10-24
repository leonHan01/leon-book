# leon-book for macOS

[English](README.md) | [简体中文](README.zh-CN.md)

This directory contains the native macOS implementation of `leon-book`. It uses SwiftUI for its windows, menus, navigation, reading, writing, and settings interfaces. Article web embeds use the system WebKit view; the app does not launch Safari or Chrome.

Articles, drafts, settings, images, and videos are stored locally. SQLite is the source of truth for structured records; HTML articles, JSON backups, and media files remain on the local filesystem. The app does not start Node.js, an external browser, or a local HTTP service.

Article edits are written to a recovery snapshot after 3 seconds of inactivity. Continuous editing creates a history point every 5 minutes, retained for 30 days by default. Version history is available from both the reader and writing workspace, with side-by-side body diffs and restore-to-editor. Autosave never overwrites published content directly; the explicit Save Draft and Publish actions remain the formal save boundary.

## Editable homepage

Choose **Edit Homepage** to change the welcome title and introduction, then **Add Module** to combine Markdown text, images, audio (including MP3), video, article content, to-do lists, quick writing, statistics, recent articles, and activity. Drag a module's header onto another module and release when it highlights, or use the arrows to reorder. Downward drops place the module after the target, and upward drops place it before the target. Each module's menu offers width settings, content-driven height, duplicate, and remove.

Resize with the right edge (width), bottom edge (height), or bottom-right corner (both). Width snaps to a 12-column grid and height to 24-point steps; live guides and a size badge show alignment. Modules wrap in reading order without overlapping. Width is at least 3 columns and roughly 240 points when space permits; height can be set from 144 to 1,920 points. Small windows temporarily stack modules without changing their saved widths. Press Esc during a resize to restore its starting size. The module editor also provides size steppers and **Fit Height to Content**. Long content scrolls inside a fixed-height module; images and video adapt to the available size. Save Homepage persists dimensions, while Cancel discards them. Existing full/half-width layouts remain compatible.

A translucent thumbnail of the module follows the pointer while dragging. It keeps the heading and visible content, cropping long modules to their top section so the destination stays visible. The preview captures the existing card without reloading articles or creating extra media players.

Use the pencil button to configure a module, apply its changes, then **Save Homepage** to persist the layout. Cancel discards layout changes; navigating within the window keeps unfinished edits. Article modules show the latest saved body, and to-do modules share the existing task list. Audio and video require a play action, and players are released when leaving the page.

Homepage settings live in each user's SQLite workspace with cross-window refresh and revision conflict protection, and are included in complete workspace backups. Files are copied to `media/dashboard/`; removing a module retains its underlying article, task, or media file.

## Media Library

The sidebar shows independent **Media Groups**. Choose **New Media Group** to create a group, right-click a group to rename or delete it, and use **Move to Group** on a card to organize its media. Article, moment, and Q&A media initially appear in **Default Group** without inheriting article folders. Imports and Finder drops go into the current group; importing from **All Media** uses Default Group. Deleting a group returns its media to Default Group without moving or deleting files or changing article references. Groups are saved per workspace and included in complete workspace backups.

Each video and audio file supports an introduction. Choose **Add Introduction / Edit Introduction** beneath a card or in the playback panel, then save your text. Cards show a two-line preview, the player shows the full scrollable text, and search matches both names and introductions. Introductions support multiple lines, editing, and clearing; they are stored in the current workspace and included in its backups.

Open **Media Library** from the navigation rail to browse videos and audio in the current workspace, including supported article, moment, and Q&A attachments. Filter by video or audio, search names, sort by date or name, and click a card for native playback. Videos include seeking, volume, fullscreen, and picture-in-picture controls; audio includes playback and seeking controls.

Use **Import Media** for multiple files or drop them from Finder. Supported containers are MP4, MOV, and M4V video, and MP3, M4A, AAC, WAV, AIFF, and CAF audio; imports validate that the system can play the file's codec. Files are copied into `media/media-library/` with their original display names, leaving source files intact, and are included in workspace backups. Closing playback pauses and releases the player, and reopening can resume saved progress. Cards load video posters on demand without allocating players.

## Search and quick navigation

The toolbar search button and `⌘⇧F` open unified full-text search across article titles, categories, tags, typed properties, excerpts, bodies, and moment text. A SQLite FTS5 index follows saves, edits, property renames, trash moves, and restores automatically and produces contextual result snippets. Filters can be combined with `tag:`, `status:draft|published`, `[property:value]`, `type:article|moment`, `date:YYYY-MM-DD`, `after:YYYY-MM-DD`, and `before:YYYY-MM-DD`; brackets preserve spaces in property names and values.

Press `⌘O` to search and open an article quickly. Press `⌘P` for a fuzzy command palette with recent and pinned commands. **Settings → Commands & Hotkeys** records, removes, or restores per-command shortcuts. Menus, URL-scheme actions, and App Intents ultimately invoke the same command registry. Type `/` at the start of an editor line to insert headings, tasks, callouts, code, tables, links, or embeds.

## TODO list

Open **Workspace → To-do** in the sidebar. Type a task and press Return to add it, or choose **New To-do** to set a priority, due date, and notes. Click a title to edit it, check a task to complete or reopen it, and use the task menu to delete it. The bottom bar can undo the most recent deletion.

Filter by open, today, overdue, all, or completed tasks, and search titles and notes. Tasks are stored in the current user's SQLite workspace, included in full workspace backups, and refreshed across windows with revision conflict checks. **Settings → First-party Modules** controls the module; the command palette offers **Go to To-do** and **New To-do**.

## Article views and bookmarks

The article library supports list, table, cards, board, and calendar layouts. Board grouping can be switched between status, category, and tags; dragging a card updates its group field, and each lane can create an article with its group value prefilled. The calendar uses update dates or a selected date property, supports creating a page for a day, and keeps undated pages in an unscheduled tray. Article properties and bookmarks remain available independently of the selected layout.

The sidebar organizes articles under directories, up to five levels deep. Articles are leaves, including `index.md` and files beside a same-named directory. New articles select a destination directory and default to `未分类` (Uncategorized). Folder creation, article saves, and resource moves validate the depth of the entire destination subtree. Existing external source paths remain intact: root articles appear under Uncategorized, and deeper content is displayed in the fifth directory. Reader and editor breadcrumbs can create another article in the same directory.

Bookmarks are shortcuts in the sidebar. Articles, individual Markdown headings, full-text searches, and the global article graph can be added or removed from their source view and reopened directly.

## Article outline and links

The reader keeps an Article Inspector on the right, so the outline, backlinks, outgoing links, unlinked mentions, and one-hop local graph stay available without scrolling to the end of a long article. Hovering a related article or graph node previews its status, excerpt, tags, and update time; clicking opens it. Unlinked mentions ignore existing `[[wiki links]]`, inline and fenced code, and Markdown links; each source row can convert all safe occurrences to wiki links with conflict protection.

Wiki links resolve case-insensitively by title, stable slug, or a unique `aliases` Property. Clicking a missing target opens a prefilled new-article draft. `[[note#heading]]` and `[[#heading]]` scroll to headings; `[[note#^block-id]]` and `[[#^block-id]]` scroll to stable paragraph, structured-block, or list-item anchors. Typing `#^` inside a wiki link searches the target note's block IDs and previews their text before insertion. Imported aliases also enter full-text search and the article-link graph.

At narrow reader widths the inspector collapses automatically. Use the Article Inspector button in the article header to open the same navigation tools in a separate panel.

## Reader tabs and history

The reader keeps an article tab strip with independent back and forward history for every tab. A normal wiki-link click continues in the current tab; hold `⌘` while clicking a body link, backlink, outgoing link, local-graph node, or article-list row to open a new tab. The Recent Articles menu also offers explicit current-tab and new-tab actions.

Pinning protects a tab from being replaced: opening another article automatically creates a new unpinned tab. Tabs, pin state, per-tab history, and the 20 most recent articles are remembered separately for each user. Use `⌘[` and `⌘]` to move backward and forward.

## Text-selection comments

The right side of the reader opens on the Comments pane. Drag across body text, or double-click a word, to quote the selection and focus the comment composer automatically. Clear the quote to leave a general article comment. Comments support replies and deletion; deleting a parent also deletes its replies.

An anchored comment stores both its source quote and nearest Markdown heading. Clicking the quote returns to that section, and the anchor is recalculated from the quote after article edits. Comments live in the current user's SQLite workspace and are included in local backups; the optional `.leonbook/` sidecar also makes them portable with the Markdown directory.

## Rich text block editing

Articles are authored and stored as semantic HTML (`.html`), with metadata in the document head. Enter creates a paragraph block, Shift+Enter inserts an inline break, and pasted paragraphs become separate blocks. The toolbar provides bold, italic, underline, strike, highlight, links, undo, and redo.

The **画板** toolbar button or `/whiteboard` inserts an offline Excalidraw drawing. Select a drawing to edit or delete it, or double-click to reopen its editor. Articles render PNG previews; the full editor is loaded only when needed. Immutable editable scenes (including image files) and previews live in `media/whiteboards/` and are backed up with the workspace. Old drawing versions are retained for undo and article history. See [Whiteboard/README.md](Whiteboard/README.md) for rebuilding the bundled resources and storage limits.

Type `/` at the beginning of a paragraph to open the searchable command menu. `/code` creates a code box with a language selector; `/callout` creates a highlighted box. Headings (`/h1`–`/h3`), lists (`/bullet`, `/number`, `/task`), `/quote`, `/table`, `/divider`, and `/text` are also available. Use arrows to choose, Enter or Tab to confirm, and Escape to dismiss. In code blocks, Enter inserts a newline and Command+Enter creates a paragraph below.

Legacy Markdown is converted once on editing. Saving writes HTML and archives the original bytes under `.legacy-markdown/`; collisions abort migration and failed saves roll back. Markdown/Obsidian round-trip compatibility is retired. Existing autosaves and revisions remain local.

## Task layouts and multiple windows

Writing, Reading, and Reviewing are three overwriteable task-layout presets. The layout menu saves the destination, editor mode, editor sidebar pane and visibility, plus the reader inspector pane and visibility; each preset can also be reset to its built-in default. Presets are stored per user, while every macOS window owns independent tabs, current article, and back/forward history. Menu commands target only the focused window.

## Portable `.leonbook/` sidecar

Settings can opt the current Markdown root into a versioned `.leonbook/` directory containing `comments.json`, `history.json`, `bookmarks.json`, `layouts.json`, and `manifest.json`. Comments and bookmarks use stable IDs plus deletion tombstones, revisions use device-independent sync IDs, and task layouts include reading preferences. SQLite remains the local query index; sidecar changes delivered by iCloud Drive, Dropbox, Syncthing, or another whole-folder file sync tool are merged automatically. Read-only mounts import but never write sidecars, and disabling the option does not delete existing files.

The sidecar is plain JSON. This phase does not provide an account service, end-to-end encryption, remote version retention, or cloud conflict-copy resolution. App-managed media remains in the LeonBook workspace and must be synchronized or backed up separately.

## Page performance and module seams

Main navigation mounts only the selected page. It no longer prewarms and permanently retains complete SwiftUI/NSHostingView trees for the dashboard, library, graph, moments, editor, and settings. Only lightweight cross-page state is cached, including collapsed moment days, per-visit impression IDs, and graph filters and zoom; image decoders, video players, WebKit instances, and large lists can be released when their page closes.

Each article's wiki-link references and mention-search document update incrementally in the body-write transaction. Opening the relation inspector reads summaries, the current article's outgoing links, candidate backlinks, and FTS mention candidates only; opening the global graph reads the link index instead of reparsing every Markdown body. Existing workspaces backfill these derived indexes once on first open.

The global article graph supports title, slug, tag, and alias search; publication-status and orphan filters; a 50–500 node cap; and 50%–180% zoom. Before drawing, the projection module ranks matching nodes by degree, clips the result, and removes edges whose endpoints are no longer visible.

Source is split along Article, Editor, Article Properties, Backup, Import, Search, Graph Projection, and Navigation Page State seams. Views keep the existing `NativeAppModel` interface, while implementation and verification stay local to the corresponding module.

`LeonBookExtensionKit` adds a separate declarative-extension seam. Versioned `extension.json` packages can contribute commands, static template variables, bounded text/JSON importers, native fenced-block renderers, and pure Base formula functions. The host never loads a dylib or hands Swift/Objective-C objects, JavaScript, a shell, network access, or arbitrary file access to an extension. Packages are validated as a whole and can be enabled, disabled, or reloaded under **Settings → Declarative Extensions**. See [`Examples/DeclarativeExtension/extension.json`](Examples/DeclarativeExtension/extension.json).

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
./scripts/leonblog restart
```

`restart` gracefully quits the running app, waits for it to exit, and relaunches it. Like `open`, it only compiles, packages, and signs when sources, resources, or build scripts have changed, or a required executable/resource bundle is missing. Use `build` to force a build. The built app is located at `macos/dist/leon-book.app` and uses ad-hoc signing for local use.

`restart` uses Debug incremental compilation by default to shorten the edit/build loop. The first Debug build populates a separate configuration cache and can still take time. Use `restart --release` for the optimized runtime, or `build` to produce Release without launching. `open` and `start` reuse the installed configuration; all four commands accept `--debug` and `--release`, or the `LEON_BOOK_BUILD_CONFIGURATION` environment variable. Build output reports compilation and packaging/signing time separately.

Debug also selects the `native` engine when available, with a cache independent of normal Release builds. On the current Swift 6.4 toolchain, adding the same comment to one Swift file took 21.24 seconds to rebuild the GUI using `swiftbuild`, versus 4.07 seconds for the GUI and 0.77 seconds for the CLI using `native`, with no concurrent source edits. A subsequent incremental build through the packaging script took 6.43 seconds including signing and verification; application quit/launch time is excluded. These are warm-cache samples, not fixed latency guarantees.

The current toolchain deprecates `native`; automatic selection falls back to the default engine if it is unavailable. Use `LEON_BOOK_BUILD_SYSTEM=default ./scripts/leonblog restart` to select the toolchain default explicitly, or set `native` / `swiftbuild` directly. See the [SwiftPM build engine migration](https://forums.swift.org/t/swiftpm-development-update-default-build-system-change/85548). Each packaging invocation uses a private staging directory and keeps the installed app until the staged signature verifies; only final installation is serialized across engines. Editor and canvas resources prefer the app's own bundle, verified by a windowless Foundation probe with no build-cache access.

To run the SwiftPM executable directly:

```bash
swift run --package-path macos LeonBook
```

`LeonBook` is the internal SwiftPM target name; the user-facing app name is `leon-book`.

## File explorer

The sidebar reads the authoritative Markdown directory as a real file tree. Folders can be expanded or collapsed, articles and attachments appear together, and the currently open article is revealed automatically. Use Command- or Shift-click for multi-selection, drag selected source items onto a folder to move them, or use the context menu to create, rename, move, reveal, and trash resources. App-managed article media is shown beside its owning article folder with a link badge; it follows the article and stays under the workspace `media/` directory.

Read-only Markdown mounts expose the same tree but disable all filesystem mutations.

## Infinite canvas

Open **Infinite Canvas** in the left navigation or from the command palette. Create multiple named boards and add live article/blog references, moments, notes, websites, images, PDFs, audio/video, and arbitrary file attachments. Drag headers to move cards, drag corners to resize, and drag edge handles to connect cards. Shift-click or Shift-drag selects multiple cards. Groups move their contained cards together; selected edges can have labels and colors.

Pan on the background, pinch or Command-scroll to zoom, and use **Fit** to show everything. Double-click creates a note; `N`, `L`, `G`, and `F` add notes, links, groups, and fit the view. Paste text/URLs, drag web links, or use the file picker for local attachments. `⌘D` duplicates, `⌘Z` undoes, and `⇧⌘Z` redoes. Article references read their current source when a board opens or the card is refreshed. Websites/PDFs load on request, with external-open actions for unsupported previews.

Boards autosave atomically to the current user's `canvases/<id>.canvas`; imported attachments are copied to `media/canvases/`. Both are part of normal workspace backups. Concurrent edits create a conflict copy instead of overwriting the other window. Deleting a board moves it into `canvases/.trash/`; references and attachments remain intact.

Import/export uses the core [JSON Canvas 1.0](https://jsoncanvas.org/spec/1.0/) node/edge structure with namespaced `leonbook` metadata. Export does not bundle attachments. Referenced files must exist at matching workspace-relative paths; missing files show placeholders. Other applications' private fields and group backgrounds are not fully preserved. The limits are 1,500 nodes, 5,000 edges, and 8 MB per board. Cards outside the viewport are unmounted, and leaving the page releases WebKit.

## Check commands

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

## Rich Markdown embeds

Obsidian-style `![[manual.pdf]]` embeds use PDFKit with continuous scrolling, while `![[recording.mp3]]` and other common AVFoundation audio formats receive inline playback controls. Both resolve through the same path-safe Vault/media lookup as images and expose an external-open fallback. Embedded files are excluded from the duplicate attachment list below an article.

Display math supports `$$…$$` plus `math`, `latex`, and `tex` fences; paragraphs containing `$…$` receive inline formula rendering. Mermaid fences render diagrams with a strict content-security policy. Formula and Mermaid source never leaves the WebView, but the pinned KaTeX and Mermaid renderer scripts are currently fetched from jsDelivr and cached by WebKit; if they are unavailable, the original source remains visible instead of disappearing.

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

The build, check, coverage, and performance scripts share SDK selection. They use the selected developer tools' SDK by default. When Command Line Tools 27.0 is selected and the 26.5 SDK is still installed, they use 26.5 to avoid the missing `SwiftUIMacros` plugin required by the 27.0 SDK's `@State` macro.

If multiple macOS SDKs are installed, use `LEON_BOOK_SDK_PATH` to explicitly select the SDK. This overrides automatic selection:

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

## External AI automation

From the repository root, run `./scripts/leonblog api capabilities` for the JSON CLI operation catalog. The CLI supports JSON Lines and a same-user Unix socket in the running app, with offline storage fallback. See the [AI automation guide](../docs/AI_AUTOMATION.md).
