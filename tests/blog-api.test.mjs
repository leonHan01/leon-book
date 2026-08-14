import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import {
  ArticleConflictError,
  createBlogApiHandler,
  createD1BlogRepository,
  ensureBlogSchema,
  SiteSettingsConflictError,
  servePublicUpload,
} from "../lib/server/blog-api.ts";

const publishedArticle = {
  body: "Visible body",
  category: "Notes",
  excerpt: "Visible excerpt",
  media: [],
  publishedAt: "2026-08-12T09:00:00.000Z",
  slug: "visible-note",
  status: "published",
  tags: ["public"],
  title: "Visible note",
  updatedAt: "2026-08-12T09:00:00.000Z",
};

const publishedSummary = {
  category: publishedArticle.category,
  excerpt: publishedArticle.excerpt,
  publishedAt: publishedArticle.publishedAt,
  slug: publishedArticle.slug,
  status: publishedArticle.status,
  tags: publishedArticle.tags,
  title: publishedArticle.title,
  updatedAt: publishedArticle.updatedAt,
  wordCount: 2,
};
const draftSummary = {
  category: publishedSummary.category,
  excerpt: publishedSummary.excerpt,
  slug: "private-draft",
  status: "draft",
  tags: publishedSummary.tags,
  title: publishedSummary.title,
  updatedAt: publishedSummary.updatedAt,
  wordCount: publishedSummary.wordCount,
};

const draftArticle = {
  body: publishedArticle.body,
  category: publishedArticle.category,
  excerpt: publishedArticle.excerpt,
  media: publishedArticle.media,
  slug: "private-draft",
  status: "draft",
  tags: publishedArticle.tags,
  title: "Private draft",
  updatedAt: publishedArticle.updatedAt,
};

test("production writes fail closed when no author allowlist is configured", async () => {
  const handle = createBlogApiHandler({
    env: {
      DB: { prepare: () => assert.fail("unauthorized requests must not access D1") },
      UPLOADS: {},
    },
  });

  const response = await handle(new Request("https://blog.example/api/articles", {
    body: JSON.stringify({ slug: "private-draft", title: "Private draft" }),
    headers: {
      "content-type": "application/json",
      "oai-authenticated-user-id": "user-1",
    },
    method: "POST",
  }));

  assert.equal(response.status, 403);
  assert.deepEqual(await response.json(), { error: "Forbidden" });
});

test("an injected authenticated email can authorize production writes case-insensitively", async () => {
  const repository = {
    async listArticles(scope) {
      assert.equal(scope, "all");
      return [draftSummary];
    },
  };
  const handle = createBlogApiHandler({
    env: {
      BLOG_AUTHOR_EMAILS: " editor@example.com , owner@example.com ",
      DB: { prepare: () => assert.fail("the injected repository should be used") },
      UPLOADS: {},
    },
    repository,
  });

  const response = await handle(new Request("https://blog.example/api/articles?scope=all", {
    headers: { "oai-authenticated-user-email": "  Editor@Example.COM " },
  }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), [draftSummary]);
});

test("cross-site and non-JSON article mutations are rejected before storage", async () => {
  const handle = createBlogApiHandler({
    env: {
      BLOG_AUTHOR_USER_IDS: "author-1",
      DB: { prepare: () => assert.fail("rejected requests must not access D1") },
      UPLOADS: { async put() {} },
    },
  });
  const authorHeader = { "oai-authenticated-user-id": "author-1" };

  const crossSite = await handle(new Request("https://blog.example/api/articles", {
    body: JSON.stringify({ title: "Forged" }),
    headers: {
      ...authorHeader,
      "content-type": "application/json",
      origin: "https://attacker.example",
      "sec-fetch-site": "cross-site",
    },
    method: "POST",
  }));
  assert.equal(crossSite.status, 403);

  const wrongType = await handle(new Request("https://blog.example/api/articles", {
    body: JSON.stringify({ title: "Wrong type" }),
    headers: { ...authorHeader, "content-type": "text/plain" },
    method: "POST",
  }));
  assert.equal(wrongType.status, 415);
});

test("the explicit local-write bypass is limited to loopback requests", async () => {
  const repository = {
    async deleteArticle() { return false; },
    async getArticle() { return null; },
    async getSiteSettings() { return null; },
    async listArticles() { return []; },
    async recordUpload() {},
    async saveArticle(_article, authorUserId) {
      assert.equal(authorUserId, "local-development-author");
      return draftArticle;
    },
    async saveSiteSettings(settings) { return settings; },
  };
  const handle = createBlogApiHandler({
    env: {
      BLOG_ALLOW_LOCAL_WRITES: "true",
      DB: { prepare: () => assert.fail("the injected repository should be used") },
      UPLOADS: { async put() {} },
    },
    repository,
  });
  const request = (origin) => new Request(`${origin}/api/articles`, {
    body: JSON.stringify({ title: "Local note" }),
    headers: { "content-type": "application/json" },
    method: "POST",
  });

  assert.equal((await handle(request("https://blog.example"))).status, 401);
  assert.equal((await handle(request("http://localhost:3000"))).status, 200);
});

test("public readers only see published articles while an allowed author can request all", async () => {
  const repository = {
    async listArticles(scope) {
      return scope === "all"
        ? [draftSummary, publishedSummary]
        : [publishedSummary];
    },
  };
  const handle = createBlogApiHandler({
    env: {
      BLOG_AUTHOR_USER_IDS: "author-1, author-2",
      DB: { prepare: () => assert.fail("the injected repository should be used") },
      UPLOADS: {},
    },
    repository,
  });

  const publicResponse = await handle(new Request("https://blog.example/api/articles"));
  assert.equal(publicResponse.status, 200);
  assert.deepEqual(await publicResponse.json(), [publishedSummary]);

  const unauthorizedResponse = await handle(new Request("https://blog.example/api/articles?scope=all"));
  assert.equal(unauthorizedResponse.status, 401);

  const authorResponse = await handle(new Request("https://blog.example/api/articles?scope=all", {
    headers: { "oai-authenticated-user-id": "author-2" },
  }));
  assert.equal(authorResponse.status, 200);
  assert.deepEqual(await authorResponse.json(), [
    draftSummary,
    publishedSummary,
  ]);
});

test("creative activity is publicly readable as daily totals", async () => {
  const activity = [{ count: 3, date: "2026-08-12" }];
  const repository = {
    async listActivity(since) {
      assert.match(since, /^\d{4}-\d{2}-\d{2}T/);
      return activity;
    },
  };
  const handle = createBlogApiHandler({
    env: {
      DB: { prepare: () => assert.fail("the injected repository should be used") },
      UPLOADS: {},
    },
    repository,
  });

  const response = await handle(new Request("https://blog.example/api/activity"));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), activity);
});

test("a draft detail is hidden by default and only exposed to an allowed author", async () => {
  const repository = {
    async getArticle(slug, includeDraft) {
      assert.equal(slug, "private-draft");
      return includeDraft ? draftArticle : null;
    },
    async listArticles() {
      return [];
    },
  };
  const handle = createBlogApiHandler({
    env: {
      BLOG_AUTHOR_USER_IDS: "author-1",
      DB: { prepare: () => assert.fail("the injected repository should be used") },
      UPLOADS: {},
    },
    repository,
  });

  const publicResponse = await handle(new Request("https://blog.example/api/articles/private-draft"));
  assert.equal(publicResponse.status, 404);

  const anonymousDraftResponse = await handle(new Request("https://blog.example/api/articles/private-draft?includeDraft=1"));
  assert.equal(anonymousDraftResponse.status, 401);

  const authorResponse = await handle(new Request("https://blog.example/api/articles/private-draft?includeDraft=1", {
    headers: { "oai-authenticated-user-id": "author-1" },
  }));
  assert.equal(authorResponse.status, 200);
  assert.deepEqual(await authorResponse.json(), draftArticle);
});

test("an allowed author can save and delete articles through the HTTP API", async () => {
  const calls = [];
  const deletedObjects = [];
  const repository = {
    async beginArticleDeletion(slug, expectedUpdatedAt) {
      calls.push(["begin-delete", slug]);
      assert.equal(expectedUpdatedAt, draftArticle.updatedAt);
      return {
        articleExisted: slug === "private-draft",
        currentArticleExists: false,
        objectKeys: ["media/123e4567-e89b-12d3-a456-426614174000.png"],
      };
    },
    async completeArticleDeletion(slug) { calls.push(["complete-delete", slug]); },
    async getArticle() {
      return null;
    },
    async listArticles() {
      return [];
    },
    async saveArticle(article, authorUserId) {
      calls.push(["save", article, authorUserId]);
      return draftArticle;
    },
  };
  const handle = createBlogApiHandler({
    env: {
      BLOG_AUTHOR_USER_IDS: "author-1",
      DB: { prepare: () => assert.fail("the injected repository should be used") },
      UPLOADS: {
        async delete(key) { deletedObjects.push(key); },
        async put() {},
      },
    },
    repository,
  });
  const authorHeaders = {
    "content-type": "application/json",
    "oai-authenticated-user-id": "author-1",
  };

  const saveResponse = await handle(new Request("https://blog.example/api/articles", {
    body: JSON.stringify({ body: "A draft", slug: "private-draft", status: "draft", title: "Private draft" }),
    headers: authorHeaders,
    method: "POST",
  }));
  assert.equal(saveResponse.status, 200);
  assert.deepEqual(await saveResponse.json(), draftArticle);
  assert.equal(calls[0][0], "save");
  assert.equal(calls[0][2], "author-1");

  const deleteResponse = await handle(new Request(`https://blog.example/api/articles/private-draft?expectedUpdatedAt=${encodeURIComponent(draftArticle.updatedAt)}`, {
    headers: { "oai-authenticated-user-id": "author-1" },
    method: "DELETE",
  }));
  assert.equal(deleteResponse.status, 200);
  assert.deepEqual(await deleteResponse.json(), { deleted: true, slug: "private-draft" });
  assert.deepEqual(calls[1], ["begin-delete", "private-draft"]);
  assert.deepEqual(calls[2], ["complete-delete", "private-draft"]);
  assert.deepEqual(deletedObjects, ["media/123e4567-e89b-12d3-a456-426614174000.png"]);
});

test("a stale article version returns 409 instead of overwriting newer content", async () => {
  const repository = {
    async beginArticleDeletion() {
      return { articleExisted: false, currentArticleExists: false, objectKeys: [] };
    },
    async completeArticleDeletion() {},
    async getArticle() { return null; },
    async getSiteSettings() { return null; },
    async listArticles() { return []; },
    async recordUpload() {},
    async saveArticle() { throw new ArticleConflictError("private-draft"); },
    async saveSiteSettings(settings) { return settings; },
  };
  const handle = createBlogApiHandler({
    env: {
      BLOG_AUTHOR_USER_IDS: "author-1",
      DB: { prepare: () => assert.fail("the injected repository should be used") },
      UPLOADS: { async put() {} },
    },
    repository,
  });

  const response = await handle(new Request("https://blog.example/api/articles", {
    body: JSON.stringify({
      expectedUpdatedAt: "2026-08-12T08:00:00.000Z",
      slug: "private-draft",
      title: "Stale edit",
    }),
    headers: {
      "content-type": "application/json",
      "oai-authenticated-user-id": "author-1",
    },
    method: "POST",
  }));
  assert.equal(response.status, 409);
  assert.deepEqual(await response.json(), {
    error: "Article was updated by another request; reload it before saving again",
    slug: "private-draft",
  });
});

test("article deletion stays retryable when an R2 object cannot be removed", async () => {
  let cleanupCompleted = false;
  const repository = {
    async beginArticleDeletion() {
      return {
        articleExisted: true,
        currentArticleExists: false,
        objectKeys: [
          "media/123e4567-e89b-12d3-a456-426614174000.png",
          "media/223e4567-e89b-12d3-a456-426614174000.png",
        ],
      };
    },
    async completeArticleDeletion() { cleanupCompleted = true; },
    async getArticle() { return null; },
    async getSiteSettings() { return null; },
    async listArticles() { return []; },
    async recordUpload() {},
    async saveArticle() { return draftArticle; },
    async saveSiteSettings(settings) { return settings; },
  };
  const handle = createBlogApiHandler({
    env: {
      BLOG_AUTHOR_USER_IDS: "author-1",
      DB: { prepare: () => assert.fail("the injected repository should be used") },
      UPLOADS: {
        async delete(key) {
          if (key.startsWith("media/2")) throw new Error("R2 unavailable");
        },
        async put() {},
      },
    },
    repository,
  });

  const response = await handle(new Request(`https://blog.example/api/articles/private-draft?expectedUpdatedAt=${encodeURIComponent(draftArticle.updatedAt)}`, {
    headers: { "oai-authenticated-user-id": "author-1" },
    method: "DELETE",
  }));
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), {
    error: "Article is deleted but media cleanup is pending; retry the request",
    failedKeys: ["media/223e4567-e89b-12d3-a456-426614174000.png"],
    retryable: true,
  });
  assert.equal(cleanupCompleted, false);
});

test("article deletion requires a current version token", async () => {
  let beginCalls = 0;
  const repository = {
    async beginArticleDeletion() {
      beginCalls += 1;
      return { articleExisted: false, currentArticleExists: true, objectKeys: [] };
    },
    async completeArticleDeletion() {},
    async getArticle() { return null; },
    async getSiteSettings() { return null; },
    async listArticles() { return []; },
    async recordUpload() {},
    async saveArticle() { return draftArticle; },
    async saveSiteSettings(settings) { return settings; },
  };
  const handle = createBlogApiHandler({
    env: {
      BLOG_AUTHOR_USER_IDS: "author-1",
      DB: { prepare: () => assert.fail("the injected repository should be used") },
      UPLOADS: { async put() {} },
    },
    repository,
  });
  const request = (query = "") => new Request(
    `https://blog.example/api/articles/private-draft${query}`,
    { headers: { "oai-authenticated-user-id": "author-1" }, method: "DELETE" },
  );

  assert.equal((await handle(request())).status, 428);
  assert.equal(beginCalls, 0);
  const staleResponse = await handle(request("?expectedUpdatedAt=stale-version"));
  assert.equal(staleResponse.status, 409);
  assert.equal(beginCalls, 1);
});

test("site settings are publicly readable but only an author can replace them", async () => {
  let settings = { language: "zh", theme: "paper" };
  const repository = {
    async deleteArticle() { return false; },
    async getArticle() { return null; },
    async getSiteSettings() { return settings; },
    async listArticles() { return []; },
    async saveArticle() { return draftArticle; },
    async saveSiteSettings(nextSettings, authorUserId, expectedUpdatedAt) {
      assert.equal(authorUserId, "author-1");
      assert.equal(expectedUpdatedAt, null);
      settings = nextSettings;
      return { settings, updatedAt: "2026-08-12T10:00:00.000Z" };
    },
  };
  const handle = createBlogApiHandler({
    env: {
      BLOG_AUTHOR_USER_IDS: "author-1",
      DB: { prepare: () => assert.fail("the injected repository should be used") },
      UPLOADS: {},
    },
    repository,
  });

  const getResponse = await handle(new Request("https://blog.example/api/site-settings"));
  assert.equal(getResponse.status, 200);
  assert.deepEqual(await getResponse.json(), settings);
  assert.equal(getResponse.headers.get("etag"), '"0"');

  const anonymousPut = await handle(new Request("https://blog.example/api/site-settings", {
    body: JSON.stringify({ language: "en", theme: "night" }),
    headers: { "content-type": "application/json" },
    method: "PUT",
  }));
  assert.equal(anonymousPut.status, 401);

  const authorPut = await handle(new Request("https://blog.example/api/site-settings", {
    body: JSON.stringify({ language: "en", theme: "night" }),
    headers: {
      "content-type": "application/json",
      "if-match": '"0"',
      "oai-authenticated-user-id": "author-1",
    },
    method: "PUT",
  }));
  assert.equal(authorPut.status, 200);
  assert.deepEqual(await authorPut.json(), { language: "en", theme: "night" });
  assert.equal(authorPut.headers.get("etag"), '"2026-08-12T10:00:00.000Z"');
});

test("a stale site-settings version returns 409 instead of overwriting newer settings", async () => {
  let saveCalls = 0;
  const repository = {
    async getSiteSettings() { return { language: "zh", theme: "paper" }; },
    async saveSiteSettings(_settings, _authorUserId, expectedUpdatedAt) {
      saveCalls += 1;
      assert.equal(expectedUpdatedAt, "2026-08-12T09:00:00.000Z");
      throw new SiteSettingsConflictError("2026-08-12T10:00:00.000Z");
    },
  };
  const handle = createBlogApiHandler({
    env: {
      BLOG_AUTHOR_USER_IDS: "author-1",
      DB: { prepare: () => assert.fail("the injected repository should be used") },
      UPLOADS: {},
    },
    repository,
  });

  const missingVersion = await handle(new Request("https://blog.example/api/site-settings", {
    body: JSON.stringify({ language: "en", theme: "night" }),
    headers: {
      "content-type": "application/json",
      "oai-authenticated-user-id": "author-1",
    },
    method: "PUT",
  }));
  assert.equal(missingVersion.status, 428);
  assert.equal(saveCalls, 0);

  const staleResponse = await handle(new Request("https://blog.example/api/site-settings", {
    body: JSON.stringify({ language: "en", theme: "night" }),
    headers: {
      "content-type": "application/json",
      "if-match": '"2026-08-12T09:00:00.000Z"',
      "oai-authenticated-user-id": "author-1",
    },
    method: "PUT",
  }));
  assert.equal(staleResponse.status, 409);
  assert.deepEqual(await staleResponse.json(), {
    error: "Site settings were updated elsewhere; reload before saving again",
    updatedAt: "2026-08-12T10:00:00.000Z",
  });
  assert.equal(staleResponse.headers.get("etag"), '"2026-08-12T10:00:00.000Z"');
  assert.equal(saveCalls, 1);
});

test("image uploads require author access and MIME-compatible magic bytes", async () => {
  const stored = [];
  const uploads = [];
  const repository = {
    async deleteArticle() { return false; },
    async getArticle() { return null; },
    async getSiteSettings() { return null; },
    async listArticles() { return []; },
    async recordUpload(upload) { uploads.push(upload); },
    async saveArticle() { return draftArticle; },
    async saveSiteSettings(settings) { return settings; },
  };
  const handle = createBlogApiHandler({
    env: {
      BLOG_AUTHOR_USER_IDS: "author-1",
      DB: { prepare: () => assert.fail("the injected repository should be used") },
      UPLOADS: {
        async delete() {},
        async put(key, body, options) {
          const bytes = new Uint8Array(await new Response(body).arrayBuffer());
          stored.push({ body: bytes, key, options });
        },
      },
    },
    repository,
  });
  const png = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 0]);

  const anonymousResponse = await handle(new Request("https://blog.example/api/imaging", {
    body: png,
    headers: { "content-type": "image/png" },
    method: "POST",
  }));
  assert.equal(anonymousResponse.status, 401);

  const mismatchResponse = await handle(new Request("https://blog.example/api/imaging", {
    body: new Uint8Array([255, 216, 255, 224]),
    headers: {
      "content-type": "image/png",
      "oai-authenticated-user-id": "author-1",
    },
    method: "POST",
  }));
  assert.equal(mismatchResponse.status, 415);
  assert.equal(stored.length, 0);

  const uploadResponse = await handle(new Request("https://blog.example/api/imaging", {
    body: png,
    headers: {
      "content-type": "image/png",
      "oai-authenticated-user-id": "author-1",
      "x-file-name": encodeURIComponent("检查影像.png"),
    },
    method: "POST",
  }));
  assert.equal(uploadResponse.status, 200);
  const result = await uploadResponse.json();
  assert.match(result.key, /^imaging\/\d{4}-\d{2}-\d{2}\/[0-9a-f-]{36}\.png$/);
  assert.equal(result.name, "检查影像.png");
  assert.equal(result.size, png.byteLength);
  assert.equal(stored.length, 1);
  assert.equal(stored[0].options.httpMetadata.contentType, "image/png");
  assert.equal(uploads[0].key, result.key);
  assert.equal(uploads[0].authorUserId, "author-1");
});

test("the media endpoint accepts a magic-checked video and enforces the actual streamed size", async () => {
  const stored = [];
  const repository = {
    async deleteArticle() { return false; },
    async getArticle() { return null; },
    async getSiteSettings() { return null; },
    async listArticles() { return []; },
    async recordUpload() {},
    async saveArticle() { return draftArticle; },
    async saveSiteSettings(settings) { return settings; },
  };
  const handle = createBlogApiHandler({
    env: {
      BLOG_AUTHOR_USER_IDS: "author-1",
      DB: { prepare: () => assert.fail("the injected repository should be used") },
      UPLOADS: {
        async delete() {},
        async put(key, body) {
          await new Response(body).arrayBuffer();
          stored.push(key);
        },
      },
    },
    repository,
  });
  const headers = {
    "content-type": "video/mp4",
    "oai-authenticated-user-id": "author-1",
  };
  const mp4Header = new Uint8Array([
    0x00, 0x00, 0x00, 0x18,
    0x66, 0x74, 0x79, 0x70,
    0x69, 0x73, 0x6f, 0x6d,
  ]);

  const response = await handle(new Request("https://blog.example/api/media?kind=video&slug=video-note", {
    body: mp4Header,
    headers,
    method: "POST",
  }));
  assert.equal(response.status, 200);
  assert.match((await response.json()).key, /^media\/[0-9a-f-]{36}\.mp4$/);
  assert.equal(stored.length, 1);

  const oversizedBody = new ReadableStream({
    start(controller) {
      controller.enqueue(mp4Header);
      const chunk = new Uint8Array(10 * 1024 * 1024);
      for (let index = 0; index < 26; index += 1) controller.enqueue(chunk);
      controller.close();
    },
  });
  const oversizedResponse = await handle(new Request("https://blog.example/api/media?kind=video", {
    body: oversizedBody,
    duplex: "half",
    headers,
    method: "POST",
  }));
  assert.equal(oversizedResponse.status, 413);
  assert.equal(stored.length, 1);
});

test("the D1 repository maps persisted JSON fields and prepares one statement at a time", async () => {
  const prepared = [];
  const outcomes = [
    { results: [{
      banner_json: null,
      body: "Visible body",
      category: "Notes",
      excerpt: "Visible excerpt",
      media_json: "[]",
      published_at: "2026-08-12T09:00:00.000Z",
      slug: "visible-note",
      status: "published",
      tags_json: "[\"public\"]",
      title: "Visible note",
      updated_at: "2026-08-12T09:00:00.000Z",
      word_count: 2,
    }] },
    {
      banner_json: null,
      body: "A draft",
      category: "Uncategorized",
      excerpt: "",
      media_json: "[]",
      published_at: null,
      slug: "private-draft",
      status: "draft",
      tags_json: "[]",
      title: "Private draft",
      updated_at: "2026-08-12T10:00:00.000Z",
    },
  ];
  const db = {
    prepare(sql) {
      const statement = {
        bindings: [],
        bind(...values) {
          this.bindings = values;
          return this;
        },
        async all() { return outcomes.shift(); },
        async first() { return outcomes.shift(); },
        async run() { return outcomes.shift(); },
        sql,
      };
      prepared.push(statement);
      return statement;
    },
  };
  const repository = createD1BlogRepository(db, {
    ensureSchema: false,
    now: () => "2026-08-12T10:00:00.000Z",
  });

  assert.deepEqual(await repository.listArticles("published"), [publishedSummary]);
  assert.deepEqual(await repository.saveArticle({
    body: "A draft",
    slug: "private-draft",
    status: "draft",
    title: "Private draft",
  }, "author-1"), {
    body: "A draft",
    category: "Uncategorized",
    excerpt: "",
    media: [],
    slug: "private-draft",
    status: "draft",
    tags: [],
    title: "Private draft",
    updatedAt: "2026-08-12T10:00:00.000Z",
  });

  await assert.rejects(
    repository.saveArticle({
      expectedUpdatedAt: "2026-08-12T08:00:00.000Z",
      slug: "private-draft",
      title: "Stale draft",
    }, "author-1"),
    (error) => error instanceof ArticleConflictError && error.slug === "private-draft",
  );

  assert.match(prepared[0].sql, /WHERE status = 'published'/);
  assert.match(prepared[1].sql, /ON CONFLICT\(slug\) DO NOTHING/);
  assert.match(prepared[2].sql, /WHERE slug = \? AND updated_at = \?/);
  assert.deepEqual(prepared[2].bindings.slice(-2), [
    "private-draft",
    "2026-08-12T08:00:00.000Z",
  ]);
  for (const statement of prepared) {
    assert.ok(statement.sql.trim().split(";").filter(Boolean).length <= 1);
  }
});

test("the D1 repository records publishing, editing, and image activity", async () => {
  const prepared = [];
  const db = {
    prepare(sql) {
      const statement = {
        bindings: [],
        bind(...values) {
          this.bindings = values;
          return this;
        },
        async first() {
          if (sql.includes("INSERT INTO articles")) {
            return {
              banner_json: null,
              body: "Published body",
              category: "Notes",
              excerpt: "",
              media_json: "[]",
              published_at: "2026-08-12T10:00:00.000Z",
              slug: "published-note",
              status: "published",
              tags_json: "[]",
              title: "Published note",
              updated_at: "2026-08-12T10:00:00.000Z",
            };
          }
          if (sql.includes("UPDATE articles SET")) {
            return {
              banner_json: null,
              body: "Edited body",
              category: "Notes",
              excerpt: "",
              media_json: "[]",
              published_at: "2026-08-11T10:00:00.000Z",
              slug: "published-note",
              status: "published",
              tags_json: "[]",
              title: "Published note",
              updated_at: "2026-08-12T10:00:00.001Z",
            };
          }
          if (sql.includes("INSERT INTO uploads")) return { object_key: "media/image.png" };
          return null;
        },
        async run() { return { success: true }; },
        sql,
      };
      prepared.push(statement);
      return statement;
    },
  };
  const repository = createD1BlogRepository(db, {
    ensureSchema: false,
    now: () => "2026-08-12T10:00:00.000Z",
  });

  await repository.saveArticle({
    body: "Published body",
    slug: "published-note",
    status: "published",
    title: "Published note",
  }, "author-1");
  await repository.saveArticle({
    body: "Edited body",
    expectedUpdatedAt: "2026-08-12T10:00:00.000Z",
    slug: "published-note",
    status: "published",
    title: "Published note",
  }, "author-1");
  await repository.recordUpload({
    articleSlug: null,
    authorUserId: "author-1",
    contentType: "image/png",
    key: "media/image.png",
    kind: "image",
    originalName: "image.png",
    size: 12,
  });

  const activityStatements = prepared.filter((statement) => statement.sql.includes("INSERT INTO activity_events"));
  assert.deepEqual(activityStatements.map((statement) => statement.bindings), [
    ["article_published", "author-1", "2026-08-12T10:00:00.000Z"],
    ["article_edited", "author-1", "2026-08-12T10:00:00.001Z"],
    ["image_published", "author-1", "2026-08-12T10:00:00.000Z"],
  ]);
});

test("the D1 settings repository conditionally advances its updated-at version", async () => {
  const prepared = [];
  const outcomes = [
    { updated_at: "2026-08-12T10:00:00.000Z" },
    null,
    {
      settings_json: JSON.stringify({ language: "en", theme: "night" }),
      updated_at: "2026-08-12T10:00:00.000Z",
    },
  ];
  const db = {
    prepare(sql) {
      const statement = {
        bindings: [],
        bind(...values) {
          this.bindings = values;
          return this;
        },
        async first() { return outcomes.shift(); },
        sql,
      };
      prepared.push(statement);
      return statement;
    },
  };
  const repository = createD1BlogRepository(db, {
    ensureSchema: false,
    now: () => "2026-08-12T10:00:00.000Z",
  });

  const saved = await repository.saveSiteSettings(
    { language: "en", theme: "night" },
    "author-1",
    "2026-08-12T09:00:00.000Z",
  );
  assert.deepEqual(saved, {
    settings: { language: "en", theme: "night" },
    updatedAt: "2026-08-12T10:00:00.000Z",
  });
  assert.match(prepared[0].sql, /WHERE id = 1 AND updated_at = \?/);
  assert.deepEqual(prepared[0].bindings.slice(-1), ["2026-08-12T09:00:00.000Z"]);

  await assert.rejects(
    repository.saveSiteSettings(
      { language: "zh", theme: "paper" },
      "author-1",
      "2026-08-12T09:00:00.000Z",
    ),
    (error) => error instanceof SiteSettingsConflictError &&
      error.currentUpdatedAt === "2026-08-12T10:00:00.000Z",
  );
  assert.match(prepared[1].sql, /WHERE id = 1 AND updated_at = \?/);
  assert.match(prepared[2].sql, /SELECT settings_json, updated_at/);
});

test("an empty local D1 is initialized once per isolate with single-statement prepares", async () => {
  const prepared = [];
  let batches = 0;
  const db = {
    async batch(statements) {
      batches += 1;
      assert.equal(statements.length, prepared.length);
      return statements.map(() => ({ success: true }));
    },
    prepare(sql) {
      const statement = {
        all: async () => ({ results: [] }),
        bind() { return this; },
        first: async () => null,
        run: async () => ({ success: true }),
        sql,
      };
      prepared.push(statement);
      return statement;
    },
  };

  await Promise.all([ensureBlogSchema(db), ensureBlogSchema(db)]);
  assert.equal(batches, 1);
  assert.match(prepared.map((statement) => statement.sql).join("\n"), /deletion_queue/);
  assert.match(prepared.map((statement) => statement.sql).join("\n"), /activity_events/);
  for (const statement of prepared) {
    assert.ok(statement.sql.trim().split(";").filter(Boolean).length <= 1);
  }
});

test("the production migrations parse in SQLite and include the activity history", async () => {
  const migrations = await Promise.all([
    readFile(new URL("../drizzle/0000_blog_storage.sql", import.meta.url), "utf8"),
    readFile(new URL("../drizzle/0001_amazing_frightful_four.sql", import.meta.url), "utf8"),
  ]);
  const database = new DatabaseSync(":memory:");
  try {
    database.exec(migrations.join("\n").replaceAll("--> statement-breakpoint", ""));
    const tables = database
      .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .all()
      .map((row) => row.name);
    assert.deepEqual(tables, ["activity_events", "articles", "deletion_queue", "site_settings", "uploads"]);
    const articleColumns = database
      .prepare("PRAGMA table_info(articles)")
      .all()
      .map((row) => row.name);
    assert.ok(articleColumns.includes("word_count"));
  } finally {
    database.close();
  }
});

test("stored media is served with immutable public caching and nosniff", async () => {
  const key = "media/123e4567-e89b-12d3-a456-426614174000.png";
  const response = await servePublicUpload(
    new Request(`https://blog.example/uploads/${key}`),
    {
      async put() {},
      async get(requestedKey) {
        assert.equal(requestedKey, key);
        return {
          body: new Blob(["image"]).stream(),
          httpEtag: '"etag-value"',
          writeHttpMetadata(headers) {
            headers.set("content-type", "image/png");
          },
        };
      },
    },
  );

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "public, max-age=31536000, immutable");
  assert.equal(response.headers.get("x-content-type-options"), "nosniff");
  assert.equal(response.headers.get("etag"), '"etag-value"');
  assert.equal(response.headers.get("content-type"), "image/png");

  const headResponse = await servePublicUpload(
    new Request(`https://blog.example/uploads/${key}`, { method: "HEAD" }),
    {
      async put() {},
      async get() {
        return {
          body: new Blob(["image"]).stream(),
          httpEtag: '"etag-value"',
          writeHttpMetadata(headers) { headers.set("content-type", "image/png"); },
        };
      },
    },
  );
  assert.equal(headResponse.status, 200);
  assert.equal(await headResponse.text(), "");
  assert.equal(headResponse.headers.get("content-type"), "image/png");
});
