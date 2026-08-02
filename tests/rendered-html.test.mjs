import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

async function render(pathname = "/") {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request(`http://localhost${pathname}`, {
      headers: { accept: "text/html" },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
}

test("server-renders the Notebook 36 homepage", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>Notebook 36 — Alex Rivera<\/title>/i);
  assert.match(html, /Notes on making/);
  assert.match(html, /Recent notes/);
  assert.match(html, /Visual archive/);
  assert.match(html, /<video/);
  assert.match(html, /Write/);
  assert.doesNotMatch(html, /codex-preview|react-loading-skeleton|Your site is taking shape/i);
});

test("keeps the starter preview removed from the finished site", async () => {
  const [page, layout, css, packageJson, settingsPage, settingsData, writePage, storageServer] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
    readFile(new URL("../package.json", import.meta.url), "utf8"),
    readFile(new URL("../app/settings/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/site-settings.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/write/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../scripts/local-storage-server.mjs", import.meta.url), "utf8"),
  ]);

  assert.match(page, /Notebook 36/);
  assert.doesNotMatch(page, /modal-backdrop|composerOpen/);
  assert.match(writePage, /editor-dropzone/);
  assert.match(writePage, /inline-media-block/);
  assert.match(writePage, /serializeBlocks/);
  assert.match(writePage, /editor-tabs/);
  assert.match(writePage, /insertMarkdown/);
  assert.match(writePage, /renderMarkdown/);
  assert.match(writePage, /renderInlineMarkdown/);
  assert.match(writePage, /Insert code block/);
  assert.match(writePage, /saveDraftNow/);
  assert.match(writePage, /publishArticle/);
  assert.match(writePage, /status,/);
  assert.match(writePage, /editor-checklist/);
  assert.match(writePage, /STORAGE_URL/);
  assert.match(page, /siteSettings/);
  assert.match(settingsPage, /settings-language/);
  assert.match(settingsData, /SETTINGS_STORAGE_KEY/);
  assert.match(settingsPage, /article-library/);
  assert.match(settingsPage, /method: "DELETE"/);
  assert.match(page, /publishedEntries/);
  assert.match(page, /status === "published"/);
  assert.match(storageServer, /async function deleteArticle/);
  assert.match(storageServer, /request.method === "DELETE"/);
  assert.match(layout, /Notebook 36/);
  assert.doesNotMatch(page, /SkeletonPreview|codex-preview|_sites-preview/);
  assert.doesNotMatch(layout, /Starter Project|codex-preview|_sites-preview/);
  assert.doesNotMatch(css, /sites-skeleton|react-loading-skeleton/);
  assert.doesNotMatch(packageJson, /react-loading-skeleton/);
  assert.match(packageJson, /scripts\/dev-with-storage\.mjs/);
  await assert.rejects(access(new URL("../app/_sites-preview", import.meta.url)));
});

test("server-renders the settings page", async () => {
  const response = await render("/settings");
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /Make the notebook yours|把这个日志变成你的空间/);
  assert.match(html, /settings-language/);
  assert.match(html, /Color theme|颜色主题/);
});

test("server-renders the dedicated writing page", async () => {
  const response = await render("/write");
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /Write something down|写下此刻的想法/);
  assert.match(html, /Drop images or videos at the cursor|将图片或视频插入光标位置/);
  assert.doesNotMatch(html, /modal-backdrop/);
});
