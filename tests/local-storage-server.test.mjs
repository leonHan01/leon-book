import assert from "node:assert/strict";
import { readdir, readFile, rm, mkdtemp } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { createBlogStorageServer } from "../scripts/local-storage-server.mjs";

const allowedOrigin = "http://localhost:3000";

async function withServer(options, callback) {
  const workDir = await mkdtemp(path.join(os.tmpdir(), "leon-blog-storage-"));
  const errors = [];
  const storage = createBlogStorageServer({
    allowedOrigins: [allowedOrigin],
    host: "127.0.0.1",
    port: 0,
    workDir,
    logger: { error: (...values) => errors.push(values) },
    ...options,
  });
  try {
    const address = await storage.start();
    assert.equal(typeof address, "object");
    const baseUrl = `http://127.0.0.1:${address.port}`;
    await callback({ baseUrl, errors, storage, workDir });
  } finally {
    await storage.stop();
    await rm(workDir, { force: true, recursive: true });
  }
}

function sendChunked(url, { chunks, headers = {}, method = "POST" }) {
  return new Promise((resolve, reject) => {
    const request = http.request(url, { headers, method }, (response) => {
      const body = [];
      response.on("data", (chunk) => body.push(chunk));
      response.once("end", () => resolve({
        body: Buffer.concat(body),
        headers: response.headers,
        status: response.statusCode,
      }));
    });
    request.once("error", reject);
    for (const chunk of chunks) request.write(chunk);
    request.end();
  });
}

async function listFiles(directory) {
  const files = [];
  async function visit(current) {
    let entries;
    try {
      entries = await readdir(current, { withFileTypes: true });
    } catch (error) {
      if (error?.code === "ENOENT") return;
      throw error;
    }
    for (const entry of entries) {
      const entryPath = path.join(current, entry.name);
      if (entry.isDirectory()) await visit(entryPath);
      else files.push(entryPath);
    }
  }
  await visit(directory);
  return files;
}

test("CORS reflects only explicitly allowed local origins", async () => {
  await withServer({}, async ({ baseUrl, errors }) => {
    const allowed = await fetch(`${baseUrl}/api/status`, {
      headers: { Origin: allowedOrigin },
    });
    assert.equal(
      allowed.status,
      200,
      `${await allowed.clone().text()} ${errors.map((entry) => entry.join(" ")).join("\n")}`,
    );
    assert.equal(allowed.headers.get("access-control-allow-origin"), allowedOrigin);
    assert.match(allowed.headers.get("vary") ?? "", /\bOrigin\b/i);

    const preflight = await fetch(`${baseUrl}/api/articles`, {
      headers: {
        "Access-Control-Request-Method": "POST",
        Origin: allowedOrigin,
      },
      method: "OPTIONS",
    });
    assert.equal(preflight.status, 204);
    assert.match(preflight.headers.get("access-control-allow-methods") ?? "", /POST/);

    const denied = await fetch(`${baseUrl}/api/status`, {
      headers: { Origin: "https://attacker.example" },
    });
    assert.equal(denied.status, 403);
    assert.equal(denied.headers.get("access-control-allow-origin"), null);
    assert.deepEqual(await denied.json(), { error: "Origin is not allowed" });

    const withoutOrigin = await fetch(`${baseUrl}/api/status`);
    assert.equal(withoutOrigin.status, 200);
    assert.equal(withoutOrigin.headers.get("access-control-allow-origin"), null);
  });
});

test("default binding is loopback-only", async () => {
  const workDir = await mkdtemp(path.join(os.tmpdir(), "leon-blog-loopback-"));
  const storage = createBlogStorageServer({
    allowedOrigins: [allowedOrigin],
    port: 0,
    workDir,
    logger: { error() {} },
  });
  try {
    const address = await storage.start();
    assert.equal(address.address, "127.0.0.1");
  } finally {
    await storage.stop();
    await rm(workDir, { force: true, recursive: true });
  }
});

test("chunked uploads are limited by bytes received and leave no partial file", async () => {
  await withServer({ maxMediaBytes: 8 }, async ({ baseUrl, workDir }) => {
    const response = await sendChunked(`${baseUrl}/api/media?slug=limit-test&kind=image`, {
      chunks: [Buffer.from("123456"), Buffer.from("789012")],
      headers: {
        Origin: allowedOrigin,
        "X-File-Name": encodeURIComponent("too-large.png"),
      },
    });

    assert.equal(response.status, 413);
    assert.equal(response.headers["access-control-allow-origin"], allowedOrigin);
    assert.deepEqual(JSON.parse(response.body.toString("utf8")), {
      error: "Media file is too large",
    });
    assert.deepEqual(await listFiles(path.join(workDir, "media")), []);
  });
});

test("concurrent article saves preserve every index entry and use atomic files", async () => {
  await withServer({}, async ({ baseUrl, workDir }) => {
    const count = 30;
    const responses = await Promise.all(Array.from({ length: count }, (_, index) =>
      fetch(`${baseUrl}/api/articles`, {
        body: JSON.stringify({
          body: `Body ${index}`,
          slug: `post-${index}`,
          status: "published",
          title: `Post ${index}`,
        }),
        headers: {
          "Content-Type": "application/json",
          Origin: allowedOrigin,
        },
        method: "POST",
      })));
    assert.ok(responses.every((response) => response.status === 200));

    const apiResponse = await fetch(`${baseUrl}/api/articles`, {
      headers: { Origin: allowedOrigin },
    });
    assert.equal(apiResponse.status, 200);
    const articles = await apiResponse.json();
    assert.equal(articles.length, count);
    assert.deepEqual(
      new Set(articles.map((article) => article.slug)),
      new Set(Array.from({ length: count }, (_, index) => `post-${index}`)),
    );

    const storedIndex = JSON.parse(
      await readFile(path.join(workDir, "articles", "index.json"), "utf8"),
    );
    assert.equal(storedIndex.length, count);
    const files = await listFiles(workDir);
    assert.equal(files.some((file) => /\.(?:tmp|upload)$/.test(file)), false);
  });
});

test("media is served with HEAD and byte ranges", async () => {
  await withServer({}, async ({ baseUrl }) => {
    const contents = Buffer.from("0123456789");
    const upload = await fetch(`${baseUrl}/api/media?slug=range-test&kind=image`, {
      body: contents,
      headers: {
        Origin: allowedOrigin,
        "X-File-Name": encodeURIComponent("sample.png"),
      },
      method: "POST",
    });
    assert.equal(upload.status, 200);
    const media = await upload.json();
    const mediaPath = new URL(media.url, baseUrl).pathname;
    assert.match(path.basename(mediaPath), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.png$/i);
    assert.equal(media.size, contents.length);

    const head = await fetch(`${baseUrl}${mediaPath}`, {
      headers: { Origin: allowedOrigin },
      method: "HEAD",
    });
    assert.equal(head.status, 200);
    assert.equal(head.headers.get("content-length"), String(contents.length));
    assert.equal(head.headers.get("accept-ranges"), "bytes");
    assert.equal((await head.arrayBuffer()).byteLength, 0);

    const range = await fetch(`${baseUrl}${mediaPath}`, {
      headers: { Origin: allowedOrigin, Range: "bytes=2-5" },
    });
    assert.equal(range.status, 206);
    assert.equal(range.headers.get("content-range"), "bytes 2-5/10");
    assert.equal(await range.text(), "2345");

    const invalidRange = await fetch(`${baseUrl}${mediaPath}`, {
      headers: { Origin: allowedOrigin, Range: "bytes=99-100" },
    });
    assert.equal(invalidRange.status, 416);
    assert.equal(invalidRange.headers.get("content-range"), "bytes */10");
  });
});

test("malformed JSON is reported as a client error", async () => {
  await withServer({}, async ({ baseUrl }) => {
    const response = await fetch(`${baseUrl}/api/articles`, {
      body: "{not-json",
      headers: {
        "Content-Type": "application/json",
        Origin: allowedOrigin,
      },
      method: "POST",
    });
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), { error: "Request body must be valid JSON" });
  });
});

test("articles remain local, hide drafts publicly, and reject stale saves", async () => {
  await withServer({}, async ({ baseUrl, workDir }) => {
    const createdResponse = await fetch(`${baseUrl}/api/articles`, {
      body: JSON.stringify({ body: "One two three", slug: "local-note", status: "draft", title: "Local note" }),
      headers: { "Content-Type": "application/json", Origin: allowedOrigin },
      method: "POST",
    });
    assert.equal(createdResponse.status, 200);
    const created = await createdResponse.json();
    assert.equal(created.wordCount, 3);

    const publicArticles = await fetch(`${baseUrl}/api/articles`, { headers: { Origin: allowedOrigin } }).then((response) => response.json());
    assert.deepEqual(publicArticles, []);
    const allArticles = await fetch(`${baseUrl}/api/articles?scope=all`, { headers: { Origin: allowedOrigin } }).then((response) => response.json());
    assert.equal(allArticles.length, 1);

    const stale = await fetch(`${baseUrl}/api/articles`, {
      body: JSON.stringify({ body: "Stale", slug: "local-note", status: "published", title: "Local note" }),
      headers: { "Content-Type": "application/json", Origin: allowedOrigin },
      method: "POST",
    });
    assert.equal(stale.status, 409);

    const updated = await fetch(`${baseUrl}/api/articles`, {
      body: JSON.stringify({
        body: "Published locally",
        expectedUpdatedAt: created.updatedAt,
        slug: "local-note",
        status: "published",
        title: "Local note",
      }),
      headers: { "Content-Type": "application/json", Origin: allowedOrigin },
      method: "POST",
    });
    assert.equal(updated.status, 200);
    assert.ok(await readFile(path.join(workDir, "articles", "local-note.json"), "utf8"));

    const activity = await fetch(`${baseUrl}/api/activity`, { headers: { Origin: allowedOrigin } }).then((response) => response.json());
    assert.equal(activity.reduce((total, day) => total + day.count, 0), 1);
  });
});

test("site settings use a local version file for conflict protection", async () => {
  await withServer({}, async ({ baseUrl, workDir }) => {
    const initial = await fetch(`${baseUrl}/api/site-settings`, { headers: { Origin: allowedOrigin } });
    assert.equal(initial.headers.get("etag"), '"0"');
    assert.equal(await initial.json(), null);

    const saved = await fetch(`${baseUrl}/api/site-settings`, {
      body: JSON.stringify({ language: "zh", theme: "paper" }),
      headers: { "Content-Type": "application/json", "If-Match": '"0"', Origin: allowedOrigin },
      method: "PUT",
    });
    assert.equal(saved.status, 200);
    const version = saved.headers.get("etag");
    assert.match(version ?? "", /^".+"$/);

    const stale = await fetch(`${baseUrl}/api/site-settings`, {
      body: JSON.stringify({ language: "en", theme: "night" }),
      headers: { "Content-Type": "application/json", "If-Match": '"0"', Origin: allowedOrigin },
      method: "PUT",
    });
    assert.equal(stale.status, 409);
    assert.ok(await readFile(path.join(workDir, "settings", "site-settings.json"), "utf8"));
  });
});
