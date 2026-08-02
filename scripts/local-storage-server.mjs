import { createWriteStream } from "node:fs";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { pipeline } from "node:stream/promises";

const WORK_DIR = path.resolve(
  process.env.BLOG_WORKDIR ?? "/Volumes/T7Shield/myblog",
);
const ARTICLES_DIR = path.join(WORK_DIR, "articles");
const MEDIA_DIR = path.join(WORK_DIR, "media");
const DRAFTS_DIR = path.join(WORK_DIR, "drafts");
const PORT = Number(process.env.BLOG_STORAGE_PORT ?? 8787);
const HOST = process.env.BLOG_STORAGE_HOST ?? "::";
const MAX_JSON_BYTES = 8 * 1024 * 1024;
const MAX_MEDIA_BYTES = 1024 * 1024 * 1024;

const contentTypes = {
  ".avif": "image/avif",
  ".gif": "image/gif",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".m4v": "video/mp4",
  ".mov": "video/quicktime",
  ".mp4": "video/mp4",
  ".png": "image/png",
  ".webm": "video/webm",
  ".webp": "image/webp",
};

const jsonHeaders = {
  "Access-Control-Allow-Headers": "Content-Type, X-File-Name, X-Media-Kind, X-Article-Slug",
  "Access-Control-Allow-Methods": "DELETE, GET, POST, OPTIONS",
  "Access-Control-Allow-Origin": "*",
  "Cache-Control": "no-store",
  "Content-Type": "application/json; charset=utf-8",
};

function respondJson(response, status, body) {
  response.writeHead(status, jsonHeaders);
  response.end(JSON.stringify(body));
}

function decodeHeader(value, fallback) {
  if (typeof value !== "string" || !value) return fallback;
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function safeSegment(value, fallback) {
  const clean = String(value ?? "")
    .normalize("NFKC")
    .replace(/[^a-zA-Z0-9._-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^[.-]+|[.-]+$/g, "")
    .slice(0, 80);
  return clean || fallback;
}

function slugify(value) {
  return safeSegment(
    String(value ?? "")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, ""),
    `draft-${Date.now()}`,
  );
}

function cleanMetadataText(value, fallback, maxLength) {
  const text = String(value ?? "").normalize("NFKC").trim().slice(0, maxLength);
  return text || fallback;
}

function normalizeTags(value) {
  const source = Array.isArray(value) ? value : String(value ?? "").split(/[\n,，]+/);
  return [...new Set(source
    .map((tag) => String(tag ?? "").normalize("NFKC").trim().replace(/^#/, "").slice(0, 40))
    .filter(Boolean))].slice(0, 12);
}

function mediaUrl(slug, filename) {
  return `http://localhost:${PORT}/media/${encodeURIComponent(slug)}/${encodeURIComponent(filename)}`;
}

async function ensureDirectories() {
  await Promise.all([
    mkdir(ARTICLES_DIR, { recursive: true }),
    mkdir(MEDIA_DIR, { recursive: true }),
    mkdir(DRAFTS_DIR, { recursive: true }),
  ]);
}

async function readJson(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_JSON_BYTES) throw new Error("JSON payload is too large");
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
}

async function saveArticle(payload) {
  const slug = slugify(payload.slug || payload.title);
  const title = String(payload.title ?? "Untitled note").trim() || "Untitled note";
  const body = String(payload.body ?? "");
  const excerpt = String(payload.excerpt ?? "");
  const category = cleanMetadataText(payload.category, "Uncategorized", 80);
  const tags = normalizeTags(payload.tags);
  const media = Array.isArray(payload.media) ? payload.media : [];
  const status = payload.status === "published" ? "published" : "draft";
  const updatedAt = new Date().toISOString();
  let previousArticle = null;
  try {
    previousArticle = JSON.parse(await readFile(path.join(ARTICLES_DIR, `${slug}.json`), "utf8"));
  } catch {
    previousArticle = null;
  }
  const publishedAt = status === "published"
    ? previousArticle?.publishedAt ?? updatedAt
    : previousArticle?.publishedAt;
  const article = { body, category, excerpt, media, slug, status, tags, title, updatedAt, ...(publishedAt ? { publishedAt } : {}) };
  const markdown = [
    "---",
    `title: ${JSON.stringify(title)}`,
    `category: ${JSON.stringify(category)}`,
    `tags: ${JSON.stringify(tags)}`,
    `slug: ${slug}`,
    `status: ${status}`,
    `updatedAt: ${updatedAt}`,
    ...(publishedAt ? [`publishedAt: ${publishedAt}`] : []),
    "---",
    "",
    body,
    "",
    media.length ? "## Media" : "",
    ...media.map((item) => `- [${item.name}](${item.url})`),
    "",
  ].join("\n");

  await Promise.all([
    writeFile(path.join(ARTICLES_DIR, `${slug}.json`), JSON.stringify(article, null, 2)),
    writeFile(path.join(ARTICLES_DIR, `${slug}.md`), markdown),
    writeFile(path.join(DRAFTS_DIR, `${slug}.json`), JSON.stringify(article, null, 2)),
  ]);

  let index = [];
  try {
    index = JSON.parse(await readFile(path.join(ARTICLES_DIR, "index.json"), "utf8"));
  } catch {
    index = [];
  }
  index = [article, ...index.filter((entry) => entry.slug !== slug)].sort((a, b) =>
    b.updatedAt.localeCompare(a.updatedAt),
  );
  await writeFile(path.join(ARTICLES_DIR, "index.json"), JSON.stringify(index, null, 2));

  return {
    articlePath: path.join(ARTICLES_DIR, `${slug}.md`),
    jsonPath: path.join(ARTICLES_DIR, `${slug}.json`),
    slug,
    updatedAt,
  };
}

async function deleteArticle(value) {
  const slug = safeSegment(value, "");
  if (!slug) throw new Error("Article slug is required");

  await Promise.all([
    rm(path.join(ARTICLES_DIR, `${slug}.json`), { force: true }),
    rm(path.join(ARTICLES_DIR, `${slug}.md`), { force: true }),
    rm(path.join(DRAFTS_DIR, `${slug}.json`), { force: true }),
    rm(path.join(MEDIA_DIR, slug), { force: true, recursive: true }),
  ]);

  let index = [];
  try {
    index = JSON.parse(await readFile(path.join(ARTICLES_DIR, "index.json"), "utf8"));
  } catch {
    index = [];
  }
  await writeFile(
    path.join(ARTICLES_DIR, "index.json"),
    JSON.stringify(index.filter((entry) => entry.slug !== slug), null, 2),
  );

  return { deleted: true, slug };
}

async function saveMedia(request, url) {
  const slug = safeSegment(url.searchParams.get("slug"), "inbox");
  const kind = url.searchParams.get("kind") === "video" ? "video" : "image";
  const originalName = decodeHeader(request.headers["x-file-name"], `${kind}.bin`);
  const extension = path.extname(originalName).toLowerCase().replace(/[^a-z0-9.]/g, "");
  const baseName = safeSegment(path.basename(originalName, path.extname(originalName)), kind);
  const filename = `${Date.now()}-${baseName}${extension}`;
  const targetDir = path.join(MEDIA_DIR, slug);
  const targetPath = path.join(targetDir, filename);
  const contentLength = Number(request.headers["content-length"] ?? 0);
  if (contentLength > MAX_MEDIA_BYTES) throw new Error("Media file is larger than 1GB");

  await mkdir(targetDir, { recursive: true });
  await pipeline(request, createWriteStream(targetPath));
  return {
    kind,
    name: originalName,
    path: targetPath,
    size: contentLength,
    url: mediaUrl(slug, filename),
  };
}

async function serveMedia(response, url) {
  const parts = url.pathname
    .slice("/media/".length)
    .split("/")
    .filter(Boolean)
    .map((part) => decodeURIComponent(part));
  if (parts.length < 2 || parts.some((part) => part === "." || part === ".." || part.includes(path.sep))) {
    response.writeHead(400);
    response.end("Bad media path");
    return;
  }
  const filePath = path.join(MEDIA_DIR, ...parts);
  try {
    const data = await readFile(filePath);
    response.writeHead(200, {
      "Access-Control-Allow-Origin": "*",
      "Cache-Control": "public, max-age=31536000, immutable",
      "Content-Type": contentTypes[path.extname(filePath).toLowerCase()] ?? "application/octet-stream",
    });
    response.end(data);
  } catch {
    response.writeHead(404);
    response.end("Not found");
  }
}

async function handle(request, response) {
  const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
  if (request.method === "OPTIONS") {
    response.writeHead(204, jsonHeaders);
    response.end();
    return;
  }
  if (request.method === "GET" && url.pathname.startsWith("/media/")) {
    await serveMedia(response, url);
    return;
  }
  if (request.method === "GET" && url.pathname === "/api/status") {
    respondJson(response, 200, { ok: true, port: PORT, workdir: WORK_DIR });
    return;
  }
  if (request.method === "DELETE" && url.pathname.startsWith("/api/articles/")) {
    const slug = decodeURIComponent(url.pathname.slice("/api/articles/".length));
    respondJson(response, 200, await deleteArticle(slug));
    return;
  }
  if (request.method === "GET" && url.pathname === "/api/articles") {
    try {
      const index = await readFile(path.join(ARTICLES_DIR, "index.json"), "utf8");
      respondJson(response, 200, JSON.parse(index));
    } catch {
      respondJson(response, 200, []);
    }
    return;
  }
  if (request.method === "POST" && url.pathname === "/api/articles") {
    respondJson(response, 200, await saveArticle(await readJson(request)));
    return;
  }
  if (request.method === "POST" && url.pathname === "/api/media") {
    respondJson(response, 200, await saveMedia(request, url));
    return;
  }
  respondJson(response, 404, { error: "Not found" });
}

await ensureDirectories();
const server = createServer((request, response) => {
  handle(request, response).catch((error) => {
    console.error("[blog-storage]", error);
    if (!response.headersSent) respondJson(response, 500, { error: error.message });
    else response.end();
  });
});

server.on("error", (error) => {
  console.error("[blog-storage] server error", error);
  process.exitCode = 1;
});

server.listen(PORT, HOST, () => {
  console.log(`[blog-storage] saving articles and media to ${WORK_DIR}`);
  console.log(`[blog-storage] local API: http://localhost:${PORT}`);
});

process.on("SIGINT", () => server.close(() => process.exit(0)));
process.on("SIGTERM", () => server.close(() => process.exit(0)));
