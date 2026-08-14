import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

async function render(pathname = "/") {
  globalThis.__CLOUDFLARE_TEST_ENV__ = {
    BLOG_AUTHOR_USER_IDS: "test-author",
  };
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request(`http://localhost${pathname}`, {
      headers: {
        accept: "text/html",
        "oai-authenticated-user-email": "author@example.com",
        "oai-authenticated-user-id": "test-author",
        "x-forwarded-host": "localhost",
        "x-forwarded-proto": "http",
      },
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
  assert.match(html, /Creative activity/);
  assert.match(html, /Visual archive/);
  assert.match(html, /<video/);
  assert.match(html, /Write/);
  assert.doesNotMatch(html, /codex-preview|react-loading-skeleton|Your site is taking shape/i);
});

test("keeps durable data, protected management, and rendering behind their intended seams", async () => {
  const [page, homeClient, layout, css, packageJson, settingsPage, settingsClient, settingsData, writePage, writeClient, articlePage, articleTypes, blogClient] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/home-client.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
    readFile(new URL("../package.json", import.meta.url), "utf8"),
    readFile(new URL("../app/settings/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/settings/settings-client.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/site-settings.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/write/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/write/write-client.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/article/[slug]/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/article-types.ts", import.meta.url), "utf8"),
    readFile(new URL("../lib/blog-client.ts", import.meta.url), "utf8"),
  ]);

  assert.match(page, /createD1BlogRepository/);
  assert.match(page, /initialArticles/);
  assert.match(homeClient, /homeCopy\.brandName/);
  assert.doesNotMatch(homeClient, /localhost:8787|STORAGE_URL/);
  assert.match(settingsPage, /requireBlogAuthor/);
  assert.match(writePage, /requireBlogAuthor/);
  assert.match(settingsClient, /listArticles\(\{ includeDrafts: true \}\)/);
  assert.doesNotMatch(settingsClient, /localhost:8787|STORAGE_URL/);
  assert.match(writeClient, /editor-dropzone/);
  assert.match(writeClient, /uploadMedia/);
  assert.match(writeClient, /saveQueue/);
  assert.match(writeClient, /renderMarkdown/);
  assert.doesNotMatch(writeClient, /function renderInlineMarkdown|localhost:8787|STORAGE_URL/);
  assert.match(blogClient, /\/api\/articles/);
  assert.match(blogClient, /\/api\/site-settings/);
  assert.match(css, /\.editor-canvas-body \.block-textarea:not\(\.primary\) \{ min-height: 68px;/);
  assert.match(articlePage, /renderArticleBody/);
  assert.match(articlePage, /generateMetadata/);
  assert.match(articlePage, /renderMarkdown/);
  assert.match(articleTypes, /export type ArticleBanner/);
  assert.match(settingsData, /normalizeSiteSettings/);
  assert.match(layout, /generateMetadata/);
  assert.match(layout, /og-notebook36\.jpg/);
  assert.doesNotMatch(homeClient, /SkeletonPreview|codex-preview|_sites-preview/);
  assert.doesNotMatch(layout, /Starter Project|codex-preview|_sites-preview/);
  assert.doesNotMatch(css, /sites-skeleton|react-loading-skeleton/);
  assert.doesNotMatch(packageJson, /react-loading-skeleton/);
  assert.match(packageJson, /"typecheck": "tsc --noEmit"/);
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
  assert.match(html, /Choose banner image|选择 Banner 图片/);
  assert.match(html, /Drop media or paste images at the cursor|拖入媒体，或在光标位置直接粘贴图片/);
  assert.doesNotMatch(html, /modal-backdrop/);
});

test("server-renders the imaging upload page", async () => {
  const response = await render("/upload");
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /上传影像/);
  assert.match(html, /新建影像批次/);
  assert.match(html, /image\/jpeg,image\/png,image\/webp,image\/gif,image\/avif/);
  assert.match(html, /上传前请检查隐私信息/);
});

test("stores imaging uploads in object storage", async () => {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `upload-${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  const stored = [];

  const response = await worker.fetch(
    new Request("http://localhost/api/imaging", {
      body: new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]),
      headers: {
        "content-type": "image/png",
        "x-file-name": encodeURIComponent("检查影像.png"),
      },
      method: "POST",
    }),
    {
      BLOG_ALLOW_LOCAL_WRITES: "true",
      DB: {
        prepare() {
          return {
            bind() { return this; },
            async first() { return { object_key: "recorded-upload" }; },
            async run() { return { success: true, results: [], meta: {} }; },
          };
        },
      },
      UPLOADS: {
        async put(key, body, options) {
          stored.push({ body, key, options });
        },
      },
    },
    { waitUntil() {}, passThroughOnException() {} },
  );

  assert.equal(response.status, 200);
  const result = await response.json();
  assert.match(result.key, /^imaging\/\d{4}-\d{2}-\d{2}\/[\w-]+\.png$/);
  assert.match(result.url, /^http:\/\/localhost\/uploads\/imaging\//);
  assert.equal(stored.length, 1);
  assert.equal(stored[0].options.httpMetadata.contentType, "image/png");
  assert.equal(stored[0].options.customMetadata.originalName, "检查影像.png");
});

test("server-renders the article detail route", async () => {
  const response = await render("/article/example");
  assert.equal(response.status, 404);
});

test("serves crawler rules and a sitemap without exposing management routes", async () => {
  const [robots, sitemap] = await Promise.all([
    render("/robots.txt"),
    render("/sitemap.xml"),
  ]);
  assert.equal(robots.status, 200);
  const robotsText = await robots.text();
  assert.match(robotsText, /Disallow: \/settings/);
  assert.match(robotsText, /Sitemap: http:\/\/localhost\/sitemap\.xml/);

  assert.equal(sitemap.status, 200);
  const sitemapText = await sitemap.text();
  assert.match(sitemapText, /<loc>http:\/\/localhost\/?<\/loc>/);
  assert.doesNotMatch(sitemapText, /\/write|\/settings|\/upload/);
});
