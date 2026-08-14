import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";

const projectRoot = path.resolve(new URL("..", import.meta.url).pathname);
let baseURL;
let frontend;
let workDir;
let frontendOutput = "";

function availablePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close((error) => error ? reject(error) : resolve(address.port));
    });
  });
}

async function waitForFrontend() {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (frontend.exitCode !== null) throw new Error(`Next.js exited early:\n${frontendOutput}`);
    try {
      const response = await fetch(baseURL, { signal: AbortSignal.timeout(500) });
      if (response.status < 500) return;
    } catch {
      // The production server may still be loading its route manifest.
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Next.js did not become ready:\n${frontendOutput}`);
}

before(async () => {
  workDir = await mkdtemp(path.join(os.tmpdir(), "notebook36-render-"));
  const frontendPort = await availablePort();
  const storagePort = await availablePort();
  baseURL = `http://127.0.0.1:${frontendPort}`;
  frontend = spawn(process.execPath, [
    "scripts/dev-with-storage.mjs",
    "--production",
    "--hostname", "127.0.0.1",
    "--port", String(frontendPort),
  ], {
    cwd: projectRoot,
    env: {
      ...process.env,
      BLOG_STORAGE_PORT: String(storagePort),
      BLOG_STORAGE_URL: `http://127.0.0.1:${storagePort}`,
      BLOG_WORKDIR: workDir,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  frontend.stdout.on("data", (chunk) => { frontendOutput += chunk.toString(); });
  frontend.stderr.on("data", (chunk) => { frontendOutput += chunk.toString(); });
  await waitForFrontend();
});

after(async () => {
  frontend?.kill("SIGTERM");
  await new Promise((resolve) => setTimeout(resolve, 100));
  if (workDir) await rm(workDir, { force: true, recursive: true });
});

async function render(pathname = "/") {
  return fetch(new URL(pathname, baseURL), { headers: { accept: "text/html" } });
}

test("server-renders the local Notebook 36 homepage", async () => {
  const response = await render();
  assert.equal(response.status, 200, frontendOutput);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);
  const html = await response.text();
  assert.match(html, /<title>Notebook 36 — Alex Rivera<\/title>/i);
  assert.match(html, /Notes on making/);
  assert.match(html, /Creative activity/);
  assert.match(html, /Visual archive/);
  assert.match(html, /Write/);
  assert.doesNotMatch(html, /codex-preview|react-loading-skeleton/i);
});

test("keeps local data and same-origin API calls behind their intended seams", async () => {
  const [page, homeClient, layout, packageJson, settingsPage, settingsClient, writePage, writeClient, articlePage, blogClient, localStorage] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/home-client.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("../package.json", import.meta.url), "utf8"),
    readFile(new URL("../app/settings/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/settings/settings-client.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/write/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/write/write-client.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/article/[slug]/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../lib/blog-client.ts", import.meta.url), "utf8"),
    readFile(new URL("../lib/server/local-storage.ts", import.meta.url), "utf8"),
  ]);

  assert.match(page, /listLocalArticles/);
  assert.match(page, /listLocalActivity/);
  assert.match(homeClient, /ActivityHeatmap/);
  assert.match(layout, /getLocalSiteSettings/);
  assert.doesNotMatch(settingsPage, /requireBlogAuthor|chatgpt/i);
  assert.doesNotMatch(writePage, /requireBlogAuthor|chatgpt/i);
  assert.match(settingsClient, /LOCAL · site-settings\.json/);
  assert.match(writeClient, /LOCAL · FILES/);
  assert.match(writeClient, /uploadMedia/);
  assert.match(articlePage, /getLocalArticle/);
  assert.match(blogClient, /\/api\/articles/);
  assert.match(localStorage, /127\.0\.0\.1:8787/);
  assert.doesNotMatch(packageJson, /cloudflare|drizzle|vinext|wrangler/i);
  await assert.rejects(access(new URL("../.openai/hosting.json", import.meta.url)));
  await assert.rejects(access(new URL("../cloudflare-env.d.ts", import.meta.url)));
  await assert.rejects(access(new URL("../worker/index.ts", import.meta.url)));
});

test("server-renders local management pages without cloud login", async () => {
  const [settings, write, upload] = await Promise.all([
    render("/settings"),
    render("/write"),
    render("/upload"),
  ]);
  assert.equal(settings.status, 200);
  assert.equal(write.status, 200);
  assert.equal(upload.status, 200);
  assert.match(await settings.text(), /Make the notebook yours|把这个日志变成你的空间/);
  assert.match(await write.text(), /Write something down|写下此刻的想法/);
  assert.match(await upload.text(), /上传影像/);
});

test("same-origin API and media routes persist only to the temporary local folder", async () => {
  const body = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
  const response = await fetch(new URL("/api/imaging", baseURL), {
    body,
    headers: {
      "content-type": "image/png",
      "x-file-name": encodeURIComponent("检查影像.png"),
    },
    method: "POST",
  });
  assert.equal(response.status, 200, await response.clone().text());
  const result = await response.json();
  assert.match(result.key, /^inbox\/[\w-]+\.png$/);
  assert.match(result.url, /^\/media\/inbox\//);
  const media = await fetch(new URL(result.url, baseURL));
  assert.equal(media.status, 200);
  assert.deepEqual(new Uint8Array(await media.arrayBuffer()), body);
});

test("crawler routes remain local and exclude management pages", async () => {
  const [robots, sitemap] = await Promise.all([render("/robots.txt"), render("/sitemap.xml")]);
  assert.equal(robots.status, 200);
  assert.match(await robots.text(), /Disallow: \/settings/);
  const sitemapText = await sitemap.text();
  assert.match(sitemapText, /127\.0\.0\.1/);
  assert.doesNotMatch(sitemapText, /\/write|\/settings|\/upload/);
});
