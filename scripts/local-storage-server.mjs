import { randomUUID } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";

const WORK_DIR = path.resolve(
  process.env.BLOG_WORKDIR ?? "/Volumes/T7Shield/myblog",
);
const PORT = Number(process.env.BLOG_STORAGE_PORT ?? 8787);
const HOST = process.env.BLOG_STORAGE_HOST ?? "127.0.0.1";
const MAX_JSON_BYTES = 8 * 1024 * 1024;
const MAX_MEDIA_BYTES = 1024 * 1024 * 1024;
const DEFAULT_ALLOWED_ORIGINS = [
  "http://localhost:3000",
  "http://127.0.0.1:3000",
];

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

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.name = "HttpError";
    this.status = status;
  }
}

function decodeHeader(value, fallback) {
  if (typeof value !== "string" || !value) return fallback;
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function decodePathSegment(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    throw new HttpError(400, "Path contains invalid encoding");
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

function requireSafeSegment(value, label) {
  const raw = String(value ?? "");
  const clean = safeSegment(raw, "");
  if (!clean || clean !== raw) {
    throw new HttpError(400, `${label} is invalid`);
  }
  return clean;
}

function slugify(value) {
  return safeSegment(
    String(value ?? "")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, ""),
    `draft-${Date.now()}-${randomUUID().slice(0, 8)}`,
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

function normalizeBanner(value) {
  if (!value || typeof value !== "object") return undefined;
  const url = String(value.url ?? "").trim();
  if (!url) return undefined;
  const name = cleanMetadataText(value.name, "banner", 180);
  return {
    alt: String(value.alt ?? name).normalize("NFKC").trim().slice(0, 300) || name,
    name,
    size: Math.max(0, Number(value.size) || 0),
    url,
  };
}

function normalizeArticle(article) {
  const source = article && typeof article === "object" ? article : {};
  return {
    ...source,
    banner: normalizeBanner(source.banner),
    body: String(source.body ?? ""),
    category: cleanMetadataText(source.category, "Uncategorized", 80),
    excerpt: String(source.excerpt ?? ""),
    media: Array.isArray(source.media) ? source.media : [],
    slug: safeSegment(source.slug, `legacy-${Date.now()}`),
    // Articles created before publication support are legacy published content.
    status: source.status === "draft" ? "draft" : "published",
    tags: normalizeTags(source.tags),
    title: String(source.title ?? "Untitled note").trim() || "Untitled note",
    updatedAt: String(source.updatedAt ?? new Date().toISOString()),
  };
}

function normalizeOrigin(value) {
  try {
    const url = new URL(String(value));
    if (
      (url.protocol !== "http:" && url.protocol !== "https:")
      || url.username
      || url.password
      || url.pathname !== "/"
      || url.search
      || url.hash
    ) {
      return null;
    }
    return url.origin;
  } catch {
    return null;
  }
}

function parseAllowedOrigins(value) {
  const entries = value === undefined
    ? DEFAULT_ALLOWED_ORIGINS
    : Array.isArray(value)
      ? value
      : String(value).split(",");
  const origins = new Set();
  for (const entry of entries) {
    const raw = String(entry).trim();
    if (!raw) continue;
    const origin = normalizeOrigin(raw);
    if (!origin) throw new Error(`Invalid allowed origin: ${raw}`);
    origins.add(origin);
  }
  return origins;
}

function declaredContentLength(request) {
  const value = request.headers["content-length"];
  if (value === undefined) return null;
  if (typeof value !== "string" || !/^\d+$/.test(value)) {
    throw new HttpError(400, "Content-Length is invalid");
  }
  const size = Number(value);
  if (!Number.isSafeInteger(size)) {
    throw new HttpError(413, "Request body is too large");
  }
  return size;
}

function isNotFound(error) {
  return error && typeof error === "object" && error.code === "ENOENT";
}

async function atomicWriteFile(targetPath, data) {
  const temporaryPath = path.join(
    path.dirname(targetPath),
    `.${path.basename(targetPath)}.${randomUUID()}.tmp`,
  );
  try {
    await writeFile(temporaryPath, data, { flag: "wx" });
    await rename(temporaryPath, targetPath);
  } catch (error) {
    await rm(temporaryPath, { force: true }).catch(() => {});
    throw error;
  }
}

async function readStoredJson(filePath, missingValue) {
  let source;
  try {
    source = await readFile(filePath, "utf8");
  } catch (error) {
    if (isNotFound(error)) return missingValue;
    throw error;
  }
  try {
    return JSON.parse(source);
  } catch {
    throw new Error("Stored JSON data is invalid");
  }
}

function readRequestBody(request, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let failure = null;

    const fail = (error) => {
      if (!failure) failure = error;
    };

    request.on("data", (chunk) => {
      if (failure) return;
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += buffer.length;
      if (size > limit) {
        chunks.length = 0;
        fail(new HttpError(413, "JSON payload is too large"));
        return;
      }
      chunks.push(buffer);
    });
    request.once("end", () => {
      if (failure) reject(failure);
      else resolve(Buffer.concat(chunks, size));
    });
    request.once("aborted", () => fail(new HttpError(400, "Request body was interrupted")));
    request.once("error", () => fail(new HttpError(400, "Request body could not be read")));
    request.once("close", () => {
      if (!request.complete && failure) reject(failure);
    });
  });
}

async function readJson(request, limit) {
  const declaredSize = declaredContentLength(request);
  if (declaredSize !== null && declaredSize > limit) {
    throw new HttpError(413, "JSON payload is too large");
  }
  const body = await readRequestBody(request, limit);
  try {
    return JSON.parse(body.toString("utf8") || "{}");
  } catch {
    throw new HttpError(400, "Request body must be valid JSON");
  }
}

function writeRequestToFile(request, targetPath, limit) {
  return new Promise((resolve, reject) => {
    const output = createWriteStream(targetPath, { flags: "wx" });
    let failure = null;
    let finished = false;
    let settled = false;
    let size = 0;

    const fail = (error) => {
      if (failure) return;
      failure = error;
      output.destroy();
      // Keep draining the request so the server can return an HTTP error instead
      // of resetting a chunked upload midway through the response.
      request.resume();
    };

    request.on("data", (chunk) => {
      if (failure) return;
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      if (size + buffer.length > limit) {
        fail(new HttpError(413, "Media file is too large"));
        return;
      }
      size += buffer.length;
      if (!output.write(buffer)) {
        request.pause();
        output.once("drain", () => {
          if (!failure) request.resume();
        });
      }
    });
    request.once("end", () => {
      if (!failure) output.end();
    });
    request.once("aborted", () => fail(new HttpError(400, "Media upload was interrupted")));
    request.once("error", () => fail(new HttpError(400, "Media upload could not be read")));

    output.once("error", (error) => {
      if (!failure) failure = error;
      request.resume();
    });
    output.once("finish", () => {
      finished = true;
    });
    output.once("close", () => {
      if (settled) return;
      settled = true;
      if (failure) reject(failure);
      else if (finished) resolve(size);
      else reject(new Error("Media file could not be written"));
    });
  });
}

function parseRange(value, size) {
  if (value === undefined) return null;
  if (typeof value !== "string") return false;
  const match = /^bytes=(\d*)-(\d*)$/.exec(value.trim());
  if (!match || (!match[1] && !match[2]) || size === 0) return false;

  let start;
  let end;
  if (!match[1]) {
    const suffixLength = Number(match[2]);
    if (!Number.isSafeInteger(suffixLength) || suffixLength <= 0) return false;
    start = Math.max(size - suffixLength, 0);
    end = size - 1;
  } else {
    start = Number(match[1]);
    end = match[2] ? Number(match[2]) : size - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end)) return false;
    if (start >= size || end < start) return false;
    end = Math.min(end, size - 1);
  }
  return { end, start };
}

function mediaUrl(origin, slug, filename) {
  return `${origin}/media/${encodeURIComponent(slug)}/${encodeURIComponent(filename)}`;
}

export function createBlogStorageServer(options = {}) {
  const workDir = path.resolve(options.workDir ?? WORK_DIR);
  const articlesDir = path.join(workDir, "articles");
  const mediaDir = path.join(workDir, "media");
  const draftsDir = path.join(workDir, "drafts");
  const port = options.port ?? PORT;
  const host = options.host ?? HOST;
  const maxJsonBytes = options.maxJsonBytes ?? MAX_JSON_BYTES;
  const maxMediaBytes = options.maxMediaBytes ?? MAX_MEDIA_BYTES;
  const allowedOrigins = parseAllowedOrigins(
    options.allowedOrigins ?? process.env.BLOG_ALLOWED_ORIGINS,
  );
  const configuredPublicOrigin = options.publicOrigin
    ?? process.env.BLOG_STORAGE_PUBLIC_ORIGIN
    ?? (port === 0 ? null : `http://localhost:${port}`);
  const publicOrigin = configuredPublicOrigin === null
    ? null
    : normalizeOrigin(configuredPublicOrigin);
  const logger = options.logger ?? console;
  let mutationQueue = Promise.resolve();

  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new Error("BLOG_STORAGE_PORT must be a valid TCP port");
  }
  if (!Number.isSafeInteger(maxJsonBytes) || maxJsonBytes <= 0) {
    throw new Error("maxJsonBytes must be a positive safe integer");
  }
  if (!Number.isSafeInteger(maxMediaBytes) || maxMediaBytes <= 0) {
    throw new Error("maxMediaBytes must be a positive safe integer");
  }
  if (configuredPublicOrigin !== null && !publicOrigin) {
    throw new Error("BLOG_STORAGE_PUBLIC_ORIGIN must be an HTTP(S) origin");
  }

  function serializeMutation(operation) {
    const result = mutationQueue.then(operation, operation);
    mutationQueue = result.then(() => undefined, () => undefined);
    return result;
  }

  function requestOrigin(request) {
    const value = request.headers.origin;
    if (value === undefined) return null;
    if (typeof value !== "string") return false;
    return normalizeOrigin(value);
  }

  function assertOriginAllowed(request) {
    const origin = requestOrigin(request);
    if (origin !== null && (!origin || !allowedOrigins.has(origin))) {
      throw new HttpError(403, "Origin is not allowed");
    }
  }

  function corsHeaders(request) {
    const origin = requestOrigin(request);
    return {
      ...(origin && allowedOrigins.has(origin)
        ? { "Access-Control-Allow-Origin": origin }
        : {}),
      "Vary": "Origin",
    };
  }

  function respondJson(request, response, status, body, extraHeaders = {}) {
    const data = Buffer.from(JSON.stringify(body));
    response.writeHead(status, {
      ...corsHeaders(request),
      "Cache-Control": "no-store",
      "Content-Length": String(data.length),
      "Content-Type": "application/json; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
      ...extraHeaders,
    });
    response.end(data);
  }

  function respondEmpty(request, response, status, extraHeaders = {}) {
    response.writeHead(status, {
      ...corsHeaders(request),
      "Content-Length": "0",
      ...extraHeaders,
    });
    response.end();
  }

  async function ensureDirectories() {
    await Promise.all([
      mkdir(articlesDir, { recursive: true }),
      mkdir(mediaDir, { recursive: true }),
      mkdir(draftsDir, { recursive: true }),
    ]);
  }

  async function saveArticleUnserialized(payload) {
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      throw new HttpError(400, "Article payload must be a JSON object");
    }
    const slug = slugify(payload.slug || payload.title);
    const title = String(payload.title ?? "Untitled note").trim() || "Untitled note";
    const body = String(payload.body ?? "");
    const excerpt = String(payload.excerpt ?? "");
    const category = cleanMetadataText(payload.category, "Uncategorized", 80);
    const tags = normalizeTags(payload.tags);
    const media = Array.isArray(payload.media) ? payload.media : [];
    const banner = normalizeBanner(payload.banner);
    const status = payload.status === "published" ? "published" : "draft";
    const updatedAt = new Date().toISOString();
    const articleJsonPath = path.join(articlesDir, `${slug}.json`);
    const previousArticle = await readStoredJson(articleJsonPath, null);
    const publishedAt = status === "published"
      ? previousArticle?.publishedAt ?? updatedAt
      : previousArticle?.publishedAt;
    const article = { banner, body, category, excerpt, media, slug, status, tags, title, updatedAt, ...(publishedAt ? { publishedAt } : {}) };
    const markdown = [
      "---",
      `title: ${JSON.stringify(title)}`,
      `category: ${JSON.stringify(category)}`,
      `tags: ${JSON.stringify(tags)}`,
      `slug: ${slug}`,
      `status: ${status}`,
      ...(banner ? [`banner: ${JSON.stringify(banner.url)}`, `bannerAlt: ${JSON.stringify(banner.alt)}`] : []),
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
      atomicWriteFile(articleJsonPath, JSON.stringify(article, null, 2)),
      atomicWriteFile(path.join(articlesDir, `${slug}.md`), markdown),
      atomicWriteFile(path.join(draftsDir, `${slug}.json`), JSON.stringify(article, null, 2)),
    ]);

    const storedIndex = await readStoredJson(path.join(articlesDir, "index.json"), []);
    if (!Array.isArray(storedIndex)) throw new Error("Stored article index is invalid");
    const index = [article, ...storedIndex.filter((entry) => entry?.slug !== slug)].sort((a, b) =>
      String(b.updatedAt).localeCompare(String(a.updatedAt)),
    );
    await atomicWriteFile(path.join(articlesDir, "index.json"), JSON.stringify(index, null, 2));

    return {
      articlePath: path.join(articlesDir, `${slug}.md`),
      jsonPath: articleJsonPath,
      slug,
      updatedAt,
    };
  }

  async function saveArticle(payload) {
    return serializeMutation(() => saveArticleUnserialized(payload));
  }

  async function deleteArticleUnserialized(value) {
    const slug = requireSafeSegment(value, "Article slug");
    const storedIndex = await readStoredJson(path.join(articlesDir, "index.json"), []);
    if (!Array.isArray(storedIndex)) throw new Error("Stored article index is invalid");

    await Promise.all([
      rm(path.join(articlesDir, `${slug}.json`), { force: true }),
      rm(path.join(articlesDir, `${slug}.md`), { force: true }),
      rm(path.join(draftsDir, `${slug}.json`), { force: true }),
      rm(path.join(mediaDir, slug), { force: true, recursive: true }),
    ]);
    await atomicWriteFile(
      path.join(articlesDir, "index.json"),
      JSON.stringify(storedIndex.filter((entry) => entry?.slug !== slug), null, 2),
    );

    return { deleted: true, slug };
  }

  async function deleteArticle(value) {
    return serializeMutation(() => deleteArticleUnserialized(value));
  }

  function currentMediaOrigin() {
    if (publicOrigin) return publicOrigin;
    const address = server.address();
    const boundPort = address && typeof address === "object" ? address.port : port;
    return `http://localhost:${boundPort}`;
  }

  async function saveMedia(request, url) {
    const slugValue = url.searchParams.get("slug");
    const slug = slugValue === null ? "inbox" : requireSafeSegment(slugValue, "Media slug");
    const kindValue = url.searchParams.get("kind");
    if (kindValue !== null && kindValue !== "image" && kindValue !== "video") {
      throw new HttpError(400, "Media kind must be image or video");
    }
    const kind = kindValue === "video" ? "video" : "image";
    const originalName = decodeHeader(request.headers["x-file-name"], `${kind}.bin`)
      .normalize("NFKC")
      .slice(0, 255);
    const originalExtension = path.extname(originalName).toLowerCase();
    const extension = /^\.[a-z0-9]{1,10}$/.test(originalExtension) ? originalExtension : "";
    const filename = `${randomUUID()}${extension}`;
    const targetDir = path.join(mediaDir, slug);
    const targetPath = path.join(targetDir, filename);
    const temporaryPath = path.join(targetDir, `.${filename}.${randomUUID()}.upload`);
    const contentLength = declaredContentLength(request);
    if (contentLength !== null && contentLength > maxMediaBytes) {
      throw new HttpError(413, "Media file is too large");
    }

    await mkdir(targetDir, { recursive: true });
    try {
      const size = await writeRequestToFile(request, temporaryPath, maxMediaBytes);
      await rename(temporaryPath, targetPath);
      return {
        kind,
        name: originalName,
        path: targetPath,
        size,
        url: mediaUrl(currentMediaOrigin(), slug, filename),
      };
    } catch (error) {
      await rm(temporaryPath, { force: true }).catch(() => {});
      await rm(targetPath, { force: true }).catch(() => {});
      throw error;
    }
  }

  function mediaPathFromUrl(url) {
    const encodedParts = url.pathname.slice("/media/".length).split("/").filter(Boolean);
    if (encodedParts.length !== 2) throw new HttpError(400, "Media path is invalid");
    const parts = encodedParts.map(decodePathSegment);
    if (parts.some((part) => part.includes("/") || part.includes("\\"))) {
      throw new HttpError(400, "Media path is invalid");
    }
    const [slug, filename] = parts;
    requireSafeSegment(slug, "Media slug");
    requireSafeSegment(filename, "Media filename");
    const filePath = path.resolve(mediaDir, slug, filename);
    if (!filePath.startsWith(`${path.resolve(mediaDir)}${path.sep}`)) {
      throw new HttpError(400, "Media path is invalid");
    }
    return filePath;
  }

  async function serveMedia(request, response, url) {
    const filePath = mediaPathFromUrl(url);
    let fileStat;
    try {
      fileStat = await stat(filePath);
    } catch (error) {
      if (isNotFound(error)) throw new HttpError(404, "Media not found");
      throw error;
    }
    if (!fileStat.isFile()) throw new HttpError(404, "Media not found");

    const range = parseRange(request.headers.range, fileStat.size);
    if (range === false) {
      respondEmpty(request, response, 416, {
        "Accept-Ranges": "bytes",
        "Content-Range": `bytes */${fileStat.size}`,
      });
      return;
    }
    const start = range ? range.start : 0;
    const end = range ? range.end : Math.max(0, fileStat.size - 1);
    const contentLength = range ? end - start + 1 : fileStat.size;
    const status = range ? 206 : 200;
    response.writeHead(status, {
      ...corsHeaders(request),
      "Accept-Ranges": "bytes",
      "Access-Control-Expose-Headers": "Accept-Ranges, Content-Length, Content-Range",
      "Cache-Control": "public, max-age=31536000, immutable",
      "Content-Length": String(contentLength),
      ...(range ? { "Content-Range": `bytes ${start}-${end}/${fileStat.size}` } : {}),
      "Content-Type": contentTypes[path.extname(filePath).toLowerCase()] ?? "application/octet-stream",
      "X-Content-Type-Options": "nosniff",
    });
    if (request.method === "HEAD" || contentLength === 0) {
      response.end();
      return;
    }
    await pipeline(createReadStream(filePath, { end, start }), response);
  }

  async function handle(request, response) {
    assertOriginAllowed(request);
    const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
    if (request.method === "OPTIONS") {
      respondEmpty(request, response, 204, {
        "Access-Control-Allow-Headers": "Content-Type, X-File-Name, X-Media-Kind, X-Article-Slug",
        "Access-Control-Allow-Methods": "DELETE, GET, HEAD, POST, OPTIONS",
        "Access-Control-Max-Age": "600",
      });
      return;
    }
    if ((request.method === "GET" || request.method === "HEAD") && url.pathname.startsWith("/media/")) {
      await serveMedia(request, response, url);
      return;
    }
    if (url.pathname.startsWith("/media/")) {
      respondJson(request, response, 405, { error: "Method not allowed" }, { Allow: "GET, HEAD, OPTIONS" });
      return;
    }
    if (request.method === "GET" && url.pathname === "/api/status") {
      respondJson(request, response, 200, {
        ok: true,
        port: server.address()?.port ?? port,
        workdir: workDir,
      });
      return;
    }
    if (request.method === "DELETE" && url.pathname.startsWith("/api/articles/")) {
      const slug = decodePathSegment(url.pathname.slice("/api/articles/".length));
      respondJson(request, response, 200, await deleteArticle(slug));
      return;
    }
    if (request.method === "GET" && url.pathname.startsWith("/api/articles/")) {
      const slug = requireSafeSegment(
        decodePathSegment(url.pathname.slice("/api/articles/".length)),
        "Article slug",
      );
      const article = await readStoredJson(path.join(articlesDir, `${slug}.json`), null);
      if (article === null) throw new HttpError(404, "Article not found");
      respondJson(request, response, 200, normalizeArticle(article));
      return;
    }
    if (request.method === "GET" && url.pathname === "/api/articles") {
      const articles = await readStoredJson(path.join(articlesDir, "index.json"), []);
      if (!Array.isArray(articles)) throw new Error("Stored article index is invalid");
      respondJson(request, response, 200, articles.map(normalizeArticle));
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/articles") {
      respondJson(request, response, 200, await saveArticle(await readJson(request, maxJsonBytes)));
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/media") {
      respondJson(request, response, 200, await saveMedia(request, url));
      return;
    }
    if (url.pathname === "/api/status") {
      respondJson(request, response, 405, { error: "Method not allowed" }, { Allow: "GET, OPTIONS" });
      return;
    }
    if (url.pathname === "/api/articles" || url.pathname.startsWith("/api/articles/")) {
      respondJson(request, response, 405, { error: "Method not allowed" }, { Allow: "DELETE, GET, POST, OPTIONS" });
      return;
    }
    if (url.pathname === "/api/media") {
      respondJson(request, response, 405, { error: "Method not allowed" }, { Allow: "POST, OPTIONS" });
      return;
    }
    respondJson(request, response, 404, { error: "Not found" });
  }

  const server = createServer((request, response) => {
    handle(request, response).catch((error) => {
      const status = error instanceof HttpError ? error.status : 500;
      if (status >= 500) logger.error("[blog-storage]", error);
      if (!response.headersSent) {
        respondJson(request, response, status, {
          error: error instanceof HttpError ? error.message : "Internal server error",
        });
      } else if (!response.writableEnded) {
        response.destroy();
      }
    });
  });

  server.on("error", (error) => {
    logger.error("[blog-storage] server error", error);
  });

  async function start() {
    await ensureDirectories();
    if (server.listening) return server.address();
    await new Promise((resolve, reject) => {
      const onError = (error) => {
        server.off("listening", onListening);
        reject(error);
      };
      const onListening = () => {
        server.off("error", onError);
        resolve();
      };
      server.once("error", onError);
      server.once("listening", onListening);
      server.listen(port, host);
    });
    return server.address();
  }

  async function stop() {
    if (!server.listening) return;
    await new Promise((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve());
    });
  }

  return {
    allowedOrigins: new Set(allowedOrigins),
    config: { host, maxJsonBytes, maxMediaBytes, port, workDir },
    handle,
    server,
    start,
    stop,
  };
}

const isMainModule = process.argv[1]
  && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isMainModule) {
  const storage = createBlogStorageServer();
  try {
    const address = await storage.start();
    const boundPort = address && typeof address === "object" ? address.port : PORT;
    console.log(`[blog-storage] saving articles and media to ${WORK_DIR}`);
    console.log(`[blog-storage] local API: http://localhost:${boundPort}`);
  } catch (error) {
    console.error("[blog-storage] failed to start", error);
    process.exitCode = 1;
  }

  const shutdown = () => {
    storage.stop()
      .then(() => process.exit(0))
      .catch((error) => {
        console.error("[blog-storage] failed to stop", error);
        process.exit(1);
      });
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}
