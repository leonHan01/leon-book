# Article whiteboards

This directory builds the offline Excalidraw 0.18.1 editor used by LeonBook's
dedicated WKWebView. React 18.3.1 and the dependency graph are pinned. The main
article editor remains plain JavaScript and loads only PNG previews.

## Rebuild the bundled resources

```sh
cd macos/Whiteboard
npm ci --ignore-scripts --legacy-peer-deps
npm run build
```

Commit the source, lockfile and generated `../Sources/LeonBook/Whiteboard/`
directory together. SwiftPM copies this directory without flattening font paths.
Normal Swift builds and the installed app do not require Node, npm, a CDN or a
local HTTP server. The resource handler serves only this bundle under
`leonboard://app/`; its CSP blocks remote requests and executable embeds.

## Article and storage contract

- The toolbar's **画板** button and `/画板` / `/whiteboard` command open one
  editor. Saving inserts the preview at the captured block; cancel leaves the
  article untouched. Select an existing board for **编辑画板 / 删除**, or
  double-click it to edit. Readers see the PNG without loading Excalidraw.
- A `figure[data-type=whiteboard]` stores `data-whiteboard-source` plus an `img`.
  The source and preview use `/media/whiteboards/<sha256>.excalidraw` and `.png`.
  Sources include Excalidraw's `files` map so pasted/imported images survive.
- Each save writes an immutable source/preview pair before replacing the article
  reference. Document and request IDs reject callbacks from a different article;
  a changed or deleted insertion target is not silently replaced.
- Files stay inside the existing workspace media directory and are included in
  workspace backups. They are retained even when absent from the current article
  because drafts, undo and article revisions can reference them. Automatic
  collection of unused whiteboard versions is intentionally not implemented.
- Scene JSON is limited to 16 MiB / 20,000 elements; PNG previews to 8 MiB and
  4096 pixels per side (normal exports are capped at 2048). File paths, JSON and
  image presence are checked by the native store. Read-only workspaces cannot
  save drawings.
- The editor is single-user. It does not connect to Excalidraw's hosted app or
  collaboration service. Exporting an article outside the workspace still needs
  its referenced media files, as with other local image attachments.

Targeted native checks are registered as `ArticleWhiteboardTests` in
`LeonBookTests`: immutable storage and validation, article round trip / undo /
stale callbacks, and an actual offline WebKit render/export. They use temporary
workspaces and hidden views; no game or production application is launched.
