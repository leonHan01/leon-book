import type { ArticleSummary, StoredArticle } from "../app/article-types";
import type { SiteSettings } from "../app/site-settings";

export class BlogRequestError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
    this.name = "BlogRequestError";
  }
}

async function requestResponse(input: string, init?: RequestInit): Promise<Response> {
  const response = await fetch(input, {
    cache: "no-store",
    ...init,
    headers: {
      Accept: "application/json",
      ...init?.headers,
    },
  });

  if (!response.ok) {
    const payload = await response.json().catch(() => null) as { error?: string } | null;
    throw new BlogRequestError(payload?.error ?? `Request failed with status ${response.status}`, response.status);
  }

  return response;
}

async function requestJson<T>(input: string, init?: RequestInit): Promise<T> {
  const response = await requestResponse(input, init);

  return response.json() as Promise<T>;
}

function siteSettingsVersion(response: Response): string | null {
  const etag = response.headers.get("etag")?.trim();
  if (!etag || !/^"[^"\\]+"$/.test(etag)) return null;
  const version = etag.slice(1, -1);
  return version === "0" ? null : version;
}

function siteSettingsIfMatch(updatedAt: string | null): string {
  return `"${updatedAt ?? "0"}"`;
}

export function listArticles(options: { includeDrafts?: boolean } = {}) {
  const query = options.includeDrafts ? "?scope=all" : "";
  return requestJson<ArticleSummary[]>(`/api/articles${query}`);
}

export function getArticle(slug: string, options: { includeDraft?: boolean } = {}) {
  const query = options.includeDraft ? "?includeDraft=1" : "";
  return requestJson<StoredArticle>(`/api/articles/${encodeURIComponent(slug)}${query}`);
}

export type SaveArticleInput = Omit<StoredArticle, "updatedAt" | "publishedAt"> & {
  expectedUpdatedAt?: string;
  publishedAt?: string;
};

export function saveArticle(article: SaveArticleInput, signal?: AbortSignal) {
  return requestJson<StoredArticle>("/api/articles", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(article),
    signal,
  });
}

export function deleteArticle(slug: string, expectedUpdatedAt: string) {
  const query = new URLSearchParams({ expectedUpdatedAt });
  return requestJson<{ deleted: true; slug: string }>(`/api/articles/${encodeURIComponent(slug)}?${query}`, {
    method: "DELETE",
  });
}

export function getSiteSettings() {
  return requestJson<unknown>("/api/site-settings");
}

export async function getVersionedSiteSettings() {
  const response = await requestResponse("/api/site-settings");
  return {
    settings: await response.json() as unknown,
    updatedAt: siteSettingsVersion(response),
  };
}

export async function putSiteSettings(
  settings: SiteSettings,
  options: {
    expectedUpdatedAt: string | null;
    keepalive?: boolean;
    signal?: AbortSignal;
  },
) {
  const response = await requestResponse("/api/site-settings", {
    method: "PUT",
    headers: {
      "Content-Type": "application/json",
      "If-Match": siteSettingsIfMatch(options.expectedUpdatedAt),
    },
    body: JSON.stringify(settings),
    keepalive: options.keepalive,
    signal: options.signal,
  });
  const updatedAt = siteSettingsVersion(response);
  if (!updatedAt) {
    throw new BlogRequestError("Site settings response did not include a version", 502);
  }
  return {
    settings: await response.json() as SiteSettings,
    updatedAt,
  };
}

export function uploadMedia(
  file: File,
  options: { kind?: "image" | "video"; slug?: string } = {},
) {
  const query = new URLSearchParams();
  if (options.kind) query.set("kind", options.kind);
  if (options.slug) query.set("slug", options.slug);
  const suffix = query.size ? `?${query.toString()}` : "";

  return requestJson<{ key: string; kind?: "image" | "video"; name: string; size: number; url: string }>(
    `/api/media${suffix}`,
    {
      method: "POST",
      headers: {
        "Content-Type": file.type || "application/octet-stream",
        "X-File-Name": encodeURIComponent(file.name),
      },
      body: file,
    },
  );
}
