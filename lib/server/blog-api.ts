export type BlogApiEnvironment = {
  BLOG_ALLOW_LOCAL_WRITES?: string;
  BLOG_AUTHOR_EMAILS?: string;
  BLOG_AUTHOR_USER_IDS?: string;
  DB: D1DatabaseLike;
  UPLOADS: R2BucketLike;
};

export type D1DatabaseLike = {
  batch?(
    statements: D1PreparedStatementLike[],
  ): Promise<Array<{ results?: Array<Record<string, unknown>> }>>;
  prepare(sql: string): D1PreparedStatementLike;
};

export type D1PreparedStatementLike = {
  all<T = Record<string, unknown>>(): Promise<{ results?: T[] }>;
  bind(...values: unknown[]): D1PreparedStatementLike;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  run(): Promise<unknown>;
};

export type R2BucketLike = {
  delete?(key: string): Promise<unknown>;
  get?(key: string): Promise<R2ObjectLike | null>;
  put(
    key: string,
    value: ArrayBuffer | ArrayBufferView | ReadableStream<Uint8Array>,
    options?: {
      customMetadata?: Record<string, string>;
      httpMetadata?: { contentType?: string };
    },
  ): Promise<unknown>;
};

export type R2ObjectLike = {
  body: ReadableStream | null;
  httpEtag: string;
  writeHttpMetadata(headers: Headers): void;
};

export type ArticleStatus = "draft" | "published";

export type StoredArticle = {
  banner?: {
    alt: string;
    name: string;
    size: number;
    url: string;
  };
  body: string;
  category: string;
  excerpt: string;
  media: Array<{
    kind: "image" | "video";
    name: string;
    size: number;
    url: string;
  }>;
  publishedAt?: string;
  slug: string;
  status: ArticleStatus;
  tags: string[];
  title: string;
  updatedAt: string;
};

export type ArticleSummary = Pick<
  StoredArticle,
  | "banner"
  | "category"
  | "excerpt"
  | "publishedAt"
  | "slug"
  | "status"
  | "tags"
  | "title"
  | "updatedAt"
> & {
  wordCount: number;
};

export type ArticleScope = "all" | "published";

export type ArticleInput = Partial<StoredArticle> & {
  body?: unknown;
  category?: unknown;
  excerpt?: unknown;
  expectedUpdatedAt?: unknown;
  media?: unknown;
  slug?: unknown;
  status?: unknown;
  tags?: unknown;
  title?: unknown;
};

export type BlogRepository = {
  beginArticleDeletion(slug: string, expectedUpdatedAt: string): Promise<{
    articleExisted: boolean;
    currentArticleExists: boolean;
    objectKeys: string[];
  }>;
  completeArticleDeletion(slug: string): Promise<void>;
  getArticle(slug: string, includeDraft: boolean): Promise<StoredArticle | null>;
  getSiteSettings(): Promise<Record<string, unknown> | null>;
  listArticles(scope: ArticleScope): Promise<ArticleSummary[]>;
  recordUpload(upload: UploadRecord): Promise<void>;
  saveArticle(article: ArticleInput, authorUserId: string): Promise<StoredArticle>;
  saveSiteSettings(
    settings: Record<string, unknown>,
    authorUserId: string,
    expectedUpdatedAt: string | null,
  ): Promise<SiteSettingsSaveResult>;
};

export type SiteSettingsSaveResult = {
  settings: Record<string, unknown>;
  updatedAt: string;
};

export type UploadRecord = {
  articleSlug: string | null;
  authorUserId: string;
  contentType: string;
  key: string;
  kind: "image" | "video";
  originalName: string;
  size: number;
};

export type BlogApiDependencies = {
  env: BlogApiEnvironment;
  repository?: BlogRepository;
};

const AUTHOR_USER_ID_HEADER = "oai-authenticated-user-id";
const AUTHOR_EMAIL_HEADER = "oai-authenticated-user-email";
const EMPTY_SITE_SETTINGS_VERSION = "0";
const SITE_SETTINGS_UPDATED_AT = Symbol("site-settings-updated-at");
const MAX_JSON_BYTES = 8 * 1024 * 1024;
const MAX_IMAGE_BYTES = 25 * 1024 * 1024;
const MAX_VIDEO_BYTES = 250 * 1024 * 1024;

const IMAGE_EXTENSIONS: Record<string, string> = {
  "image/avif": ".avif",
  "image/gif": ".gif",
  "image/jpeg": ".jpg",
  "image/png": ".png",
  "image/webp": ".webp",
};

const VIDEO_EXTENSIONS: Record<string, string> = {
  "video/mp4": ".mp4",
  "video/quicktime": ".mov",
  "video/webm": ".webm",
};

export class ArticleConflictError extends Error {
  readonly slug: string;

  constructor(slug: string) {
    super("Article was updated by another request; reload it before saving again");
    this.name = "ArticleConflictError";
    this.slug = slug;
  }
}

export class SiteSettingsConflictError extends Error {
  readonly currentUpdatedAt: string | null;

  constructor(currentUpdatedAt: string | null) {
    super("Site settings were updated elsewhere; reload before saving again");
    this.name = "SiteSettingsConflictError";
    this.currentUpdatedAt = currentUpdatedAt;
  }
}

class HttpError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

function json(body: unknown, status = 200, extraHeaders?: HeadersInit): Response {
  return Response.json(body, {
    status,
    headers: {
      "Cache-Control": "no-store",
      ...Object.fromEntries(new Headers(extraHeaders)),
    },
  });
}

function isLocalRequest(request: Request): boolean {
  const hostname = new URL(request.url).hostname;
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]";
}

type AuthorAuthorization =
  | { status: "authorized"; userId: string }
  | { status: "unauthenticated" }
  | { status: "forbidden" };

function authorizeAuthor(request: Request, env: BlogApiEnvironment): AuthorAuthorization {
  const userId = request.headers.get(AUTHOR_USER_ID_HEADER)?.trim();
  const email = request.headers.get(AUTHOR_EMAIL_HEADER)?.trim().toLowerCase();
  if (env.BLOG_ALLOW_LOCAL_WRITES === "true" && isLocalRequest(request)) {
    return { status: "authorized", userId: userId || "local-development-author" };
  }
  if (!userId && !email) return { status: "unauthenticated" };

  const allowedUserIds = new Set(
    (env.BLOG_AUTHOR_USER_IDS ?? "")
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean),
  );
  const allowedEmails = new Set(
    (env.BLOG_AUTHOR_EMAILS ?? "")
      .split(",")
      .map((value) => value.trim().toLowerCase())
      .filter(Boolean),
  );
  return (Boolean(userId) && allowedUserIds.has(userId!)) || (Boolean(email) && allowedEmails.has(email!))
    ? { status: "authorized", userId: userId || `email:${email}` }
    : { status: "forbidden" };
}

function siteSettingsEtag(updatedAt: string | null): string {
  return `"${updatedAt ?? EMPTY_SITE_SETTINGS_VERSION}"`;
}

function expectedSiteSettingsVersion(request: Request): string | null {
  const ifMatch = request.headers.get("if-match")?.trim();
  if (!ifMatch) throw new HttpError(428, "If-Match is required");
  if (!/^"[^"\\]+"$/.test(ifMatch)) {
    throw new HttpError(400, "If-Match must contain one strong site-settings ETag");
  }
  const version = ifMatch.slice(1, -1);
  return version === EMPTY_SITE_SETTINGS_VERSION ? null : version;
}

function authorizationError(authorization: AuthorAuthorization): Response | null {
  if (authorization.status === "unauthenticated") {
    return json({ error: "Unauthorized" }, 401);
  }
  if (authorization.status === "forbidden") {
    return json({ error: "Forbidden" }, 403);
  }
  return null;
}

function mutationOriginError(request: Request): Response | null {
  const fetchSite = request.headers.get("sec-fetch-site")?.toLowerCase();
  if (fetchSite && fetchSite !== "same-origin" && fetchSite !== "none") {
    return json({ error: "Cross-site mutations are forbidden" }, 403);
  }

  const origin = request.headers.get("origin");
  if (!origin) return null;
  try {
    if (new URL(origin).origin === new URL(request.url).origin) return null;
  } catch {
    // Invalid and opaque origins are not trusted for mutations.
  }
  return json({ error: "Cross-site mutations are forbidden" }, 403);
}

function jsonContentTypeError(request: Request): Response | null {
  return contentTypeOf(request) === "application/json"
    ? null
    : json({ error: "Content-Type must be application/json" }, 415);
}

async function readLimitedBytes(request: Request, maximumBytes: number): Promise<Uint8Array> {
  const declaredLength = Number(request.headers.get("content-length") ?? 0);
  if (Number.isFinite(declaredLength) && declaredLength > maximumBytes) {
    throw new HttpError(413, "Request body is too large");
  }

  const reader = request.body?.getReader();
  if (!reader) return new Uint8Array();

  const chunks: Uint8Array[] = [];
  let byteLength = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    byteLength += value.byteLength;
    if (byteLength > maximumBytes) {
      await reader.cancel().catch(() => undefined);
      throw new HttpError(413, "Request body is too large");
    }
    chunks.push(value);
  }

  const result = new Uint8Array(byteLength);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

async function readJsonObject(request: Request): Promise<Record<string, unknown>> {
  const bytes = await readLimitedBytes(request, MAX_JSON_BYTES);
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(bytes) || "{}");
  } catch {
    throw new HttpError(400, "Invalid JSON body");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new HttpError(400, "JSON body must be an object");
  }
  return parsed as Record<string, unknown>;
}

function articleSlug(pathname: string): string {
  let slug: string;
  try {
    slug = decodeURIComponent(pathname.slice("/api/articles/".length));
  } catch {
    throw new HttpError(400, "Invalid article slug");
  }
  if (!slug || slug.includes("/")) throw new HttpError(400, "Invalid article slug");
  return slug;
}

function contentTypeOf(request: Request): string {
  return (request.headers.get("content-type") ?? "")
    .split(";", 1)[0]
    .trim()
    .toLowerCase();
}

function hasBytes(bytes: Uint8Array, offset: number, expected: readonly number[]): boolean {
  return expected.every((value, index) => bytes[offset + index] === value);
}

function hasAscii(bytes: Uint8Array, offset: number, expected: string): boolean {
  return [...expected].every((value, index) => bytes[offset + index] === value.charCodeAt(0));
}

function hasBmffBrand(bytes: Uint8Array, brands: readonly string[]): boolean {
  if (bytes.byteLength < 12 || !hasAscii(bytes, 4, "ftyp")) return false;
  for (let offset = 8; offset + 4 <= Math.min(bytes.byteLength, 64); offset += 4) {
    if (brands.some((brand) => hasAscii(bytes, offset, brand))) return true;
  }
  return false;
}

function bytesMatchContentType(bytes: Uint8Array, contentType: string): boolean {
  switch (contentType) {
    case "image/avif":
      return hasBmffBrand(bytes, ["avif", "avis"]);
    case "image/gif":
      return hasAscii(bytes, 0, "GIF87a") || hasAscii(bytes, 0, "GIF89a");
    case "image/jpeg":
      return hasBytes(bytes, 0, [0xff, 0xd8, 0xff]);
    case "image/png":
      return hasBytes(bytes, 0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    case "image/webp":
      return hasAscii(bytes, 0, "RIFF") && hasAscii(bytes, 8, "WEBP");
    case "video/mp4":
    case "video/quicktime":
      return bytes.byteLength >= 12 && hasAscii(bytes, 4, "ftyp");
    case "video/webm":
      return hasBytes(bytes, 0, [0x1a, 0x45, 0xdf, 0xa3]);
    default:
      return false;
  }
}

function safeFileName(value: string | null, fallback: string): string {
  if (!value) return fallback;
  let decoded = value;
  try {
    decoded = decodeURIComponent(value);
  } catch {
    // A raw non-URI-encoded header is still safe after sanitizing it below.
  }
  const cleaned = decoded
    .normalize("NFKC")
    .replace(/[\\/\u0000-\u001f\u007f]/g, "-")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 180);
  return cleaned || fallback;
}

function uploadUrl(request: Request, key: string): string {
  const encodedKey = key.split("/").map(encodeURIComponent).join("/");
  return new URL(`/uploads/${encodedKey}`, request.url).toString();
}

type PreparedUploadBody = {
  body: ReadableStream<Uint8Array>;
  byteLength(): number;
  cancel(): Promise<void>;
  limitExceeded(): boolean;
  prefix: Uint8Array;
};

async function prepareUploadBody(
  request: Request,
  maximumBytes: number,
): Promise<PreparedUploadBody> {
  const declaredLength = Number(request.headers.get("content-length") ?? 0);
  if (Number.isFinite(declaredLength) && declaredLength > maximumBytes) {
    throw new HttpError(413, "Request body is too large");
  }

  const reader = request.body?.getReader();
  if (!reader) throw new HttpError(400, "Media content is empty");

  const bufferedChunks: Uint8Array[] = [];
  let bufferedByteLength = 0;
  let sourceEnded = false;
  while (bufferedByteLength < 64) {
    const { done, value } = await reader.read();
    if (done) {
      sourceEnded = true;
      break;
    }
    bufferedByteLength += value.byteLength;
    if (bufferedByteLength > maximumBytes) {
      await reader.cancel().catch(() => undefined);
      throw new HttpError(413, "Request body is too large");
    }
    bufferedChunks.push(value);
  }
  if (!bufferedByteLength) throw new HttpError(400, "Media content is empty");

  const prefix = new Uint8Array(Math.min(64, bufferedByteLength));
  let prefixOffset = 0;
  for (const chunk of bufferedChunks) {
    if (prefixOffset >= prefix.byteLength) break;
    const remaining = prefix.byteLength - prefixOffset;
    const fragment = chunk.subarray(0, Math.min(chunk.byteLength, remaining));
    prefix.set(fragment, prefixOffset);
    prefixOffset += fragment.byteLength;
  }

  let bufferedIndex = 0;
  let receivedByteLength = bufferedByteLength;
  let exceededLimit = false;
  const body = new ReadableStream<Uint8Array>({
    async cancel(reason) {
      await reader.cancel(reason).catch(() => undefined);
    },
    async pull(controller) {
      if (bufferedIndex < bufferedChunks.length) {
        controller.enqueue(bufferedChunks[bufferedIndex]);
        bufferedIndex += 1;
        return;
      }
      if (sourceEnded) {
        controller.close();
        return;
      }

      try {
        const { done, value } = await reader.read();
        if (done) {
          sourceEnded = true;
          controller.close();
          return;
        }
        receivedByteLength += value.byteLength;
        if (receivedByteLength > maximumBytes) {
          exceededLimit = true;
          await reader.cancel().catch(() => undefined);
          controller.error(new HttpError(413, "Request body is too large"));
          return;
        }
        controller.enqueue(value);
      } catch (error) {
        controller.error(error);
      }
    },
  });

  return {
    body,
    byteLength: () => receivedByteLength,
    cancel: () => reader.cancel().catch(() => undefined),
    limitExceeded: () => exceededLimit,
    prefix,
  };
}

async function uploadMedia(
  request: Request,
  url: URL,
  env: BlogApiEnvironment,
  repository: BlogRepository,
  authorUserId: string,
): Promise<Response> {
  const contentType = contentTypeOf(request);
  const isImage = Object.hasOwn(IMAGE_EXTENSIONS, contentType);
  const isVideo = Object.hasOwn(VIDEO_EXTENSIONS, contentType);
  const imagingOnly = url.pathname === "/api/imaging";
  const requestedKind = url.searchParams.get("kind") === "video" ? "video" : "image";
  const kind = imagingOnly ? "image" : requestedKind;

  if ((kind === "image" && !isImage) || (kind === "video" && !isVideo)) {
    throw new HttpError(415, kind === "image"
      ? "Only JPG, PNG, WebP, GIF, or AVIF images are supported"
      : "Only MP4, MOV, or WebM videos are supported");
  }

  const uploadBody = await prepareUploadBody(
    request,
    kind === "image" ? MAX_IMAGE_BYTES : MAX_VIDEO_BYTES,
  );
  if (!bytesMatchContentType(uploadBody.prefix, contentType)) {
    await uploadBody.cancel();
    throw new HttpError(415, "Media bytes do not match the declared content type");
  }

  const extension = kind === "image"
    ? IMAGE_EXTENSIONS[contentType]
    : VIDEO_EXTENSIONS[contentType];
  const fallbackName = `${kind}${extension}`;
  const originalName = safeFileName(request.headers.get("x-file-name"), fallbackName);
  const prefix = imagingOnly
    ? `imaging/${new Date().toISOString().slice(0, 10)}`
    : "media";
  const key = `${prefix}/${crypto.randomUUID()}${extension}`;
  const articleSlugValue = url.searchParams.get("slug")?.trim().slice(0, 160) || null;

  try {
    await env.UPLOADS.put(key, uploadBody.body, {
      httpMetadata: { contentType },
      customMetadata: {
        originalName,
        uploaderUserId: authorUserId,
      },
    });
  } catch (error) {
    await env.UPLOADS.delete?.(key).catch(() => undefined);
    if (uploadBody.limitExceeded()) {
      throw new HttpError(413, "Request body is too large");
    }
    throw error;
  }

  const byteLength = uploadBody.byteLength();

  try {
    await repository.recordUpload({
      articleSlug: articleSlugValue,
      authorUserId,
      contentType,
      key,
      kind,
      originalName,
      size: byteLength,
    });
  } catch (error) {
    await env.UPLOADS.delete?.(key).catch(() => undefined);
    throw error;
  }

  return json({
    key,
    kind,
    name: originalName,
    size: byteLength,
    url: uploadUrl(request, key),
  });
}

type ArticleRow = {
  banner_json: string | null;
  body: string;
  category: string;
  excerpt: string;
  media_json: string;
  published_at: string | null;
  slug: string;
  status: string;
  tags_json: string;
  title: string;
  updated_at: string;
};

type SiteSettingsRow = {
  settings_json: string;
  updated_at: string;
};

type ArticleSummaryRow = {
  banner_json: string | null;
  category: string;
  excerpt: string;
  published_at: string | null;
  slug: string;
  status: string;
  tags_json: string;
  title: string;
  updated_at: string;
  word_count: number;
};

const ARTICLE_DETAIL_COLUMNS = `
  slug, title, body, excerpt, category, tags_json, media_json, banner_json,
  status, updated_at, published_at
`;

const ARTICLE_SUMMARY_COLUMNS = `
  slug, title, excerpt, category, tags_json, banner_json, status,
  updated_at, published_at, word_count
`;

const LIST_PUBLISHED_ARTICLES_SQL = `
  SELECT ${ARTICLE_SUMMARY_COLUMNS}
  FROM articles
  WHERE status = 'published'
  ORDER BY published_at DESC, updated_at DESC
`;

const LIST_ALL_ARTICLES_SQL = `
  SELECT ${ARTICLE_SUMMARY_COLUMNS}
  FROM articles
  ORDER BY updated_at DESC
`;

const GET_PUBLISHED_ARTICLE_SQL = `
  SELECT ${ARTICLE_DETAIL_COLUMNS}
  FROM articles
  WHERE slug = ? AND status = 'published'
  LIMIT 1
`;

const GET_ANY_ARTICLE_SQL = `
  SELECT ${ARTICLE_DETAIL_COLUMNS}
  FROM articles
  WHERE slug = ?
  LIMIT 1
`;

const INSERT_ARTICLE_SQL = `
  INSERT INTO articles (
    slug, title, body, excerpt, category, tags_json, media_json, banner_json,
    status, word_count, author_user_id, updated_by, created_at, updated_at,
    published_at
  )
  SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
  WHERE NOT EXISTS (
    SELECT 1 FROM deletion_queue WHERE article_slug = ?
  )
  ON CONFLICT(slug) DO NOTHING
  RETURNING ${ARTICLE_DETAIL_COLUMNS}
`;

const UPDATE_ARTICLE_SQL = `
  UPDATE articles SET
    title = ?,
    body = ?,
    excerpt = ?,
    category = ?,
    tags_json = ?,
    media_json = ?,
    banner_json = ?,
    status = ?,
    word_count = ?,
    updated_by = ?,
    updated_at = ?,
    published_at = CASE
      WHEN ? = 'published' THEN COALESCE(published_at, ?)
      ELSE published_at
    END
  WHERE slug = ? AND updated_at = ?
  RETURNING ${ARTICLE_DETAIL_COLUMNS}
`;

const QUEUE_ARTICLE_UPLOADS_SQL = `
  INSERT INTO deletion_queue (object_key, article_slug, created_at)
  SELECT object_key, article_slug, ?
  FROM uploads
  WHERE article_slug = ?
    AND EXISTS (
      SELECT 1 FROM articles
      WHERE slug = ? AND updated_at = ?
    )
  ON CONFLICT(object_key) DO NOTHING
`;

const LIST_QUEUED_UPLOAD_KEYS_SQL = `
  SELECT object_key
  FROM deletion_queue
  WHERE article_slug = ?
  ORDER BY created_at
`;

const DELETE_ARTICLE_UPLOADS_SQL = `
  DELETE FROM uploads
  WHERE article_slug = ?
    AND EXISTS (
      SELECT 1 FROM articles
      WHERE slug = ? AND updated_at = ?
    )
`;

const DELETE_ARTICLE_SQL = `
  DELETE FROM articles
  WHERE slug = ? AND updated_at = ?
  RETURNING slug
`;

const ARTICLE_EXISTS_SQL = `
  SELECT slug
  FROM articles
  WHERE slug = ?
  LIMIT 1
`;

const COMPLETE_ARTICLE_DELETION_SQL = `
  DELETE FROM deletion_queue
  WHERE article_slug = ?
`;

const GET_SITE_SETTINGS_SQL = `
  SELECT settings_json, updated_at
  FROM site_settings
  WHERE id = 1
  LIMIT 1
`;

const INSERT_SITE_SETTINGS_SQL = `
  INSERT INTO site_settings (id, settings_json, updated_at, updated_by)
  VALUES (1, ?, ?, ?)
  ON CONFLICT(id) DO NOTHING
  RETURNING updated_at
`;

const UPDATE_SITE_SETTINGS_SQL = `
  UPDATE site_settings SET
    settings_json = ?,
    updated_at = ?,
    updated_by = ?
  WHERE id = 1 AND updated_at = ?
  RETURNING updated_at
`;

const RECORD_UPLOAD_SQL = `
  INSERT INTO uploads (
    object_key, article_slug, kind, original_name, content_type, byte_size,
    author_user_id, created_at
  )
  SELECT ?, ?, ?, ?, ?, ?, ?, ?
  WHERE ? IS NULL OR NOT EXISTS (
    SELECT 1 FROM deletion_queue WHERE article_slug = ?
  )
  RETURNING object_key
`;

const BLOG_SCHEMA_SQL = [
  `CREATE TABLE IF NOT EXISTS articles (
    slug TEXT PRIMARY KEY NOT NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL DEFAULT '',
    excerpt TEXT NOT NULL DEFAULT '',
    category TEXT NOT NULL DEFAULT 'Uncategorized',
    tags_json TEXT NOT NULL DEFAULT '[]',
    media_json TEXT NOT NULL DEFAULT '[]',
    banner_json TEXT,
    status TEXT NOT NULL DEFAULT 'draft' CHECK(status IN ('draft', 'published')),
    word_count INTEGER NOT NULL DEFAULT 0 CHECK(word_count >= 0),
    author_user_id TEXT NOT NULL,
    updated_by TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    published_at TEXT
  )`,
  `CREATE INDEX IF NOT EXISTS articles_publication_idx
    ON articles (status, published_at, updated_at)`,
  `CREATE INDEX IF NOT EXISTS articles_updated_at_idx
    ON articles (updated_at)`,
  `CREATE TABLE IF NOT EXISTS site_settings (
    id INTEGER PRIMARY KEY NOT NULL CHECK(id = 1),
    settings_json TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    updated_by TEXT NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS uploads (
    object_key TEXT PRIMARY KEY NOT NULL,
    article_slug TEXT,
    kind TEXT NOT NULL CHECK(kind IN ('image', 'video')),
    original_name TEXT NOT NULL,
    content_type TEXT NOT NULL,
    byte_size INTEGER NOT NULL CHECK(byte_size >= 0),
    author_user_id TEXT NOT NULL,
    created_at TEXT NOT NULL
  )`,
  `CREATE INDEX IF NOT EXISTS uploads_article_slug_idx
    ON uploads (article_slug, created_at)`,
  `CREATE TABLE IF NOT EXISTS deletion_queue (
    object_key TEXT PRIMARY KEY NOT NULL,
    article_slug TEXT NOT NULL,
    created_at TEXT NOT NULL
  )`,
  `CREATE INDEX IF NOT EXISTS deletion_queue_article_slug_idx
    ON deletion_queue (article_slug, created_at)`,
] as const;

const schemaInitialization = new WeakMap<D1DatabaseLike, Promise<void>>();

export function ensureBlogSchema(database: D1DatabaseLike): Promise<void> {
  const existing = schemaInitialization.get(database);
  if (existing) return existing;

  const initialization = (async () => {
    const statements = BLOG_SCHEMA_SQL.map((sql) => database.prepare(sql));
    if (database.batch) {
      await database.batch(statements);
      return;
    }
    for (const statement of statements) await statement.run();
  })().catch((error) => {
    schemaInitialization.delete(database);
    throw error;
  });
  schemaInitialization.set(database, initialization);
  return initialization;
}

function parseJson(value: string | null, fallback: unknown): unknown {
  if (!value) return fallback;
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}

function withSiteSettingsVersion(
  settings: Record<string, unknown>,
  updatedAt: string,
): Record<string, unknown> {
  Object.defineProperty(settings, SITE_SETTINGS_UPDATED_AT, {
    configurable: false,
    enumerable: false,
    value: updatedAt,
    writable: false,
  });
  return settings;
}

function siteSettingsVersion(settings: Record<string, unknown> | null): string | null {
  if (!settings) return null;
  const version = (settings as Record<symbol, unknown>)[SITE_SETTINGS_UPDATED_AT];
  return typeof version === "string" ? version : null;
}

function articleFromRow(row: ArticleRow): StoredArticle {
  const tags = parseJson(row.tags_json, []);
  const media = parseJson(row.media_json, []);
  const banner = parseJson(row.banner_json, null);
  return {
    ...(banner && typeof banner === "object" ? { banner: banner as StoredArticle["banner"] } : {}),
    body: row.body,
    category: row.category,
    excerpt: row.excerpt,
    media: Array.isArray(media) ? media as StoredArticle["media"] : [],
    ...(row.published_at ? { publishedAt: row.published_at } : {}),
    slug: row.slug,
    status: row.status === "published" ? "published" : "draft",
    tags: Array.isArray(tags) ? tags.map(String) : [],
    title: row.title,
    updatedAt: row.updated_at,
  };
}

function articleSummaryFromRow(row: ArticleSummaryRow): ArticleSummary {
  const tags = parseJson(row.tags_json, []);
  const banner = parseJson(row.banner_json, null);
  return {
    ...(banner && typeof banner === "object" ? { banner: banner as ArticleSummary["banner"] } : {}),
    category: row.category,
    excerpt: row.excerpt,
    ...(row.published_at ? { publishedAt: row.published_at } : {}),
    slug: row.slug,
    status: row.status === "published" ? "published" : "draft",
    tags: Array.isArray(tags) ? tags.map(String) : [],
    title: row.title,
    updatedAt: row.updated_at,
    wordCount: Math.max(0, Number(row.word_count) || 0),
  };
}

function cleanText(value: unknown, fallback: string, maximumLength: number): string {
  const result = String(value ?? "").normalize("NFKC").trim().slice(0, maximumLength);
  return result || fallback;
}

function normalizeSlug(value: unknown, title: string, now: string): string {
  const source = String(value ?? title)
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}._-]+/gu, "-")
    .replace(/-+/g, "-")
    .replace(/^[.-]+|[.-]+$/g, "")
    .slice(0, 160);
  return source || `draft-${Date.parse(now) || Date.now()}`;
}

function normalizeTags(value: unknown): string[] {
  const values = Array.isArray(value) ? value : String(value ?? "").split(/[\n,，]+/);
  return [...new Set(values
    .map((tag) => String(tag ?? "").normalize("NFKC").trim().replace(/^#/, "").slice(0, 40))
    .filter(Boolean))].slice(0, 12);
}

function countWords(value: string): number {
  return value.match(
    /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]|[\p{L}\p{N}]+/gu,
  )?.length ?? 0;
}

function nextUpdatedAt(candidate: string, expected: string | null): string {
  if (!expected) return candidate;
  const candidateTime = Date.parse(candidate);
  const expectedTime = Date.parse(expected);
  if (Number.isFinite(candidateTime) && Number.isFinite(expectedTime) && candidateTime <= expectedTime) {
    return new Date(expectedTime + 1).toISOString();
  }
  return candidate;
}

function normalizeMedia(value: unknown): StoredArticle["media"] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((item) => {
    if (!item || typeof item !== "object") return [];
    const source = item as Record<string, unknown>;
    const url = String(source.url ?? "").trim();
    if (!url) return [];
    return [{
      kind: source.kind === "video" ? "video" as const : "image" as const,
      name: cleanText(source.name, "media", 180),
      size: Math.max(0, Number(source.size) || 0),
      url,
    }];
  });
}

function normalizeBanner(value: unknown): StoredArticle["banner"] | undefined {
  if (!value || typeof value !== "object") return undefined;
  const source = value as Record<string, unknown>;
  const url = String(source.url ?? "").trim();
  if (!url) return undefined;
  const name = cleanText(source.name, "banner", 180);
  return {
    alt: cleanText(source.alt, name, 300),
    name,
    size: Math.max(0, Number(source.size) || 0),
    url,
  };
}

function normalizeArticleInput(
  input: ArticleInput,
  now: string,
): Omit<StoredArticle, "updatedAt" | "publishedAt"> {
  const title = cleanText(input.title, "Untitled note", 240);
  const banner = normalizeBanner(input.banner);
  return {
    ...(banner ? { banner } : {}),
    body: String(input.body ?? ""),
    category: cleanText(input.category, "Uncategorized", 80),
    excerpt: String(input.excerpt ?? "").slice(0, 2000),
    media: normalizeMedia(input.media),
    slug: normalizeSlug(input.slug, title, now),
    status: input.status === "published" ? "published" : "draft",
    tags: normalizeTags(input.tags),
    title,
  };
}

export function createD1BlogRepository(
  database: D1DatabaseLike,
  options: { ensureSchema?: boolean; now?: () => string } = {},
): BlogRepository {
  const now = options.now ?? (() => new Date().toISOString());
  const ready = () => options.ensureSchema === true
    ? ensureBlogSchema(database)
    : Promise.resolve();

  return {
    async beginArticleDeletion(slug, expectedUpdatedAt) {
      await ready();
      if (!database.batch) {
        throw new Error("D1 batch support is required for article deletion");
      }
      const queuedAt = now();
      const queueUploads = database
        .prepare(QUEUE_ARTICLE_UPLOADS_SQL)
        .bind(queuedAt, slug, slug, expectedUpdatedAt);
      const deleteUploads = database
        .prepare(DELETE_ARTICLE_UPLOADS_SQL)
        .bind(slug, slug, expectedUpdatedAt);
      const deleteArticle = database
        .prepare(DELETE_ARTICLE_SQL)
        .bind(slug, expectedUpdatedAt);
      const results = await database.batch([queueUploads, deleteUploads, deleteArticle]);
      const [queued, currentArticle] = await Promise.all([
        database
          .prepare(LIST_QUEUED_UPLOAD_KEYS_SQL)
          .bind(slug)
          .all<{ object_key: string }>(),
        database.prepare(ARTICLE_EXISTS_SQL).bind(slug).first<{ slug: string }>(),
      ]);
      return {
        articleExisted: Boolean(results[2]?.results?.length),
        currentArticleExists: Boolean(currentArticle),
        objectKeys: (queued.results ?? []).map((row) => row.object_key),
      };
    },

    async completeArticleDeletion(slug) {
      await ready();
      await database.prepare(COMPLETE_ARTICLE_DELETION_SQL).bind(slug).run();
    },

    async getArticle(slug, includeDraft) {
      await ready();
      const row = await database
        .prepare(includeDraft ? GET_ANY_ARTICLE_SQL : GET_PUBLISHED_ARTICLE_SQL)
        .bind(slug)
        .first<ArticleRow>();
      return row ? articleFromRow(row) : null;
    },

    async getSiteSettings() {
      await ready();
      const row = await database.prepare(GET_SITE_SETTINGS_SQL).first<SiteSettingsRow>();
      const parsed = parseJson(row?.settings_json ?? null, null);
      return row && parsed && typeof parsed === "object" && !Array.isArray(parsed)
        ? withSiteSettingsVersion(parsed as Record<string, unknown>, row.updated_at)
        : null;
    },

    async listArticles(scope) {
      await ready();
      const result = await database
        .prepare(scope === "all" ? LIST_ALL_ARTICLES_SQL : LIST_PUBLISHED_ARTICLES_SQL)
        .all<ArticleSummaryRow>();
      return (result.results ?? []).map(articleSummaryFromRow);
    },

    async recordUpload(upload) {
      await ready();
      const row = await database.prepare(RECORD_UPLOAD_SQL).bind(
        upload.key,
        upload.articleSlug,
        upload.kind,
        upload.originalName,
        upload.contentType,
        upload.size,
        upload.authorUserId,
        now(),
        upload.articleSlug,
        upload.articleSlug,
      ).first<{ object_key: string }>();
      if (!row) {
        throw new HttpError(409, "Article deletion is pending; use another slug");
      }
    },

    async saveArticle(input, authorUserId) {
      await ready();
      const expectedUpdatedAt = typeof input.expectedUpdatedAt === "string"
        ? input.expectedUpdatedAt.trim() || null
        : null;
      const updatedAt = nextUpdatedAt(now(), expectedUpdatedAt);
      const article = normalizeArticleInput(input, updatedAt);
      const wordCount = countWords(article.body);
      const row = expectedUpdatedAt
        ? await database.prepare(UPDATE_ARTICLE_SQL).bind(
            article.title,
            article.body,
            article.excerpt,
            article.category,
            JSON.stringify(article.tags),
            JSON.stringify(article.media),
            article.banner ? JSON.stringify(article.banner) : null,
            article.status,
            wordCount,
            authorUserId,
            updatedAt,
            article.status,
            updatedAt,
            article.slug,
            expectedUpdatedAt,
          ).first<ArticleRow>()
        : await database.prepare(INSERT_ARTICLE_SQL).bind(
            article.slug,
            article.title,
            article.body,
            article.excerpt,
            article.category,
            JSON.stringify(article.tags),
            JSON.stringify(article.media),
            article.banner ? JSON.stringify(article.banner) : null,
            article.status,
            wordCount,
            authorUserId,
            authorUserId,
            updatedAt,
            updatedAt,
            article.status === "published" ? updatedAt : null,
            article.slug,
          ).first<ArticleRow>();
      if (!row) throw new ArticleConflictError(article.slug);
      return articleFromRow(row);
    },

    async saveSiteSettings(settings, authorUserId, expectedUpdatedAt) {
      await ready();
      const updatedAt = nextUpdatedAt(now(), expectedUpdatedAt);
      const saved = await database.prepare(
        expectedUpdatedAt === null ? INSERT_SITE_SETTINGS_SQL : UPDATE_SITE_SETTINGS_SQL,
      ).bind(
        JSON.stringify(settings),
        updatedAt,
        authorUserId,
        ...(expectedUpdatedAt === null ? [] : [expectedUpdatedAt]),
      ).first<{ updated_at: string }>();
      if (!saved) {
        const current = await database
          .prepare(GET_SITE_SETTINGS_SQL)
          .first<SiteSettingsRow>();
        throw new SiteSettingsConflictError(current?.updated_at ?? null);
      }
      return { settings, updatedAt: saved.updated_at };
    },
  };
}

const PUBLIC_UPLOAD_KEY = /^(?:imaging\/\d{4}-\d{2}-\d{2}|media)\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(?:avif|gif|jpe?g|mov|mp4|png|webm|webp)$/i;

export async function servePublicUpload(
  request: Request,
  uploads: R2BucketLike,
): Promise<Response> {
  const url = new URL(request.url);
  let key: string;
  try {
    key = decodeURIComponent(url.pathname.slice("/uploads/".length));
  } catch {
    return new Response("Bad upload path", { status: 400 });
  }
  if (!PUBLIC_UPLOAD_KEY.test(key)) {
    return new Response("Bad upload path", { status: 400 });
  }
  if (!uploads.get) return new Response("Object storage unavailable", { status: 503 });

  const object = await uploads.get(key);
  if (!object) return new Response("Not found", { status: 404 });

  const headers = new Headers({
    "Cache-Control": "public, max-age=31536000, immutable",
    "X-Content-Type-Options": "nosniff",
  });
  object.writeHttpMetadata(headers);
  headers.set("ETag", object.httpEtag);

  if (request.headers.get("if-none-match") === object.httpEtag) {
    return new Response(null, { headers, status: 304 });
  }
  return new Response(request.method === "HEAD" ? null : object.body, { headers });
}

export function createBlogApiHandler({ env, repository }: BlogApiDependencies) {
  return async function handleBlogApi(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const blogRepository = repository ?? createD1BlogRepository(env.DB, {
      ensureSchema:
        env.BLOG_ALLOW_LOCAL_WRITES === "true" && isLocalRequest(request),
    });

    if (request.method === "GET" && url.pathname === "/api/articles") {
      const scope: ArticleScope = url.searchParams.get("scope") === "all" ? "all" : "published";
      if (scope === "all") {
        const authError = authorizationError(authorizeAuthor(request, env));
        if (authError) return authError;
      }
      return json(await blogRepository.listArticles(scope));
    }

    if (request.method === "GET" && url.pathname.startsWith("/api/articles/")) {
      const includeDraft =
        url.searchParams.get("includeDraft") === "1" ||
        url.searchParams.get("includeDraft") === "true" ||
        url.searchParams.get("scope") === "all";
      if (includeDraft) {
        const authError = authorizationError(authorizeAuthor(request, env));
        if (authError) return authError;
      }
      try {
        const slug = articleSlug(url.pathname);

        const article = await blogRepository.getArticle(slug, includeDraft);
        return article ? json(article) : json({ error: "Article not found" }, 404);
      } catch (error) {
        if (error instanceof HttpError) return json({ error: error.message }, error.status);
        throw error;
      }
    }

    if (request.method === "POST" && url.pathname === "/api/articles") {
      const requestSecurityError = mutationOriginError(request) ?? jsonContentTypeError(request);
      if (requestSecurityError) return requestSecurityError;
      const authorization = authorizeAuthor(request, env);
      const authError = authorizationError(authorization);
      if (authError) return authError;
      try {
        const article = await blogRepository.saveArticle(
          await readJsonObject(request),
          authorization.status === "authorized" ? authorization.userId : "",
        );
        return json(article);
      } catch (error) {
        if (error instanceof ArticleConflictError) {
          return json({ error: error.message, slug: error.slug }, 409);
        }
        if (error instanceof HttpError) return json({ error: error.message }, error.status);
        throw error;
      }
    }

    if (request.method === "DELETE" && url.pathname.startsWith("/api/articles/")) {
      const requestSecurityError = mutationOriginError(request);
      if (requestSecurityError) return requestSecurityError;
      const authError = authorizationError(authorizeAuthor(request, env));
      if (authError) return authError;
      try {
        const slug = articleSlug(url.pathname);
        const expectedUpdatedAt = url.searchParams.get("expectedUpdatedAt")?.trim();
        if (!expectedUpdatedAt) {
          return json({ error: "expectedUpdatedAt is required" }, 428);
        }
        const deletion = await blogRepository.beginArticleDeletion(slug, expectedUpdatedAt);
        if (deletion.currentArticleExists) {
          return json({
            error: "Article was updated by another request; reload it before deleting",
            slug,
          }, 409);
        }
        if (!deletion.articleExisted && !deletion.objectKeys.length) {
          return json({ error: "Article not found" }, 404);
        }
        if (deletion.objectKeys.length) {
          const deleteObject = env.UPLOADS.delete?.bind(env.UPLOADS);
          if (!deleteObject) {
            return json({
              error: "Article is deleted but media cleanup is pending; retry the request",
              retryable: true,
            }, 503);
          }
          const deleteResults = await Promise.allSettled(
            deletion.objectKeys.map((key) => deleteObject(key)),
          );
          const failedKeys = deletion.objectKeys.filter(
            (_key, index) => deleteResults[index].status === "rejected",
          );
          if (failedKeys.length) {
            return json({
              error: "Article is deleted but media cleanup is pending; retry the request",
              failedKeys,
              retryable: true,
            }, 502);
          }
        }
        await blogRepository.completeArticleDeletion(slug);
        return json({ deleted: true, slug });
      } catch (error) {
        if (error instanceof HttpError) return json({ error: error.message }, error.status);
        throw error;
      }
    }

    if (request.method === "GET" && url.pathname === "/api/site-settings") {
      const settings = await blogRepository.getSiteSettings();
      return json(settings ?? {}, 200, {
        ETag: siteSettingsEtag(siteSettingsVersion(settings)),
      });
    }

    if (request.method === "PUT" && url.pathname === "/api/site-settings") {
      const requestSecurityError = mutationOriginError(request) ?? jsonContentTypeError(request);
      if (requestSecurityError) return requestSecurityError;
      const authorization = authorizeAuthor(request, env);
      const authError = authorizationError(authorization);
      if (authError) return authError;
      try {
        const expectedUpdatedAt = expectedSiteSettingsVersion(request);
        const saved = await blogRepository.saveSiteSettings(
          await readJsonObject(request),
          authorization.status === "authorized" ? authorization.userId : "",
          expectedUpdatedAt,
        );
        return json(saved.settings, 200, { ETag: siteSettingsEtag(saved.updatedAt) });
      } catch (error) {
        if (error instanceof SiteSettingsConflictError) {
          return json({
            error: error.message,
            updatedAt: error.currentUpdatedAt,
          }, 409, {
            ETag: siteSettingsEtag(error.currentUpdatedAt),
          });
        }
        if (error instanceof HttpError) return json({ error: error.message }, error.status);
        throw error;
      }
    }

    if (
      request.method === "POST" &&
      (url.pathname === "/api/media" || url.pathname === "/api/imaging")
    ) {
      const requestSecurityError = mutationOriginError(request);
      if (requestSecurityError) return requestSecurityError;
      const authorization = authorizeAuthor(request, env);
      const authError = authorizationError(authorization);
      if (authError) return authError;
      try {
        return await uploadMedia(
          request,
          url,
          env,
          blogRepository,
          authorization.status === "authorized" ? authorization.userId : "",
        );
      } catch (error) {
        if (error instanceof HttpError) return json({ error: error.message }, error.status);
        throw error;
      }
    }

    return json({ error: "Not found" }, 404);
  };
}
