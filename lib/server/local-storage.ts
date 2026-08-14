import type { ActivityDay } from "../../app/activity-types";
import type { ArticleSummary, StoredArticle } from "../../app/article-types";

const DEFAULT_STORAGE_ORIGIN = "http://127.0.0.1:8787";
const LOCAL_HOSTNAMES = new Set(["localhost", "127.0.0.1", "[::1]"]);

export function localStorageOrigin(): URL {
  const value = process.env.BLOG_STORAGE_URL ?? DEFAULT_STORAGE_ORIGIN;
  const url = new URL(value);
  if (url.protocol !== "http:" || !LOCAL_HOSTNAMES.has(url.hostname) || url.username || url.password) {
    throw new Error("BLOG_STORAGE_URL must point to a local HTTP service");
  }
  return new URL(url.origin);
}

export async function localStorageResponse(pathname: string, init?: RequestInit): Promise<Response> {
  const response = await fetch(new URL(pathname, localStorageOrigin()), {
    cache: "no-store",
    ...init,
  });
  if (!response.ok) {
    const payload = await response.json().catch(() => null) as { error?: string } | null;
    throw new Error(payload?.error ?? `Local storage request failed with status ${response.status}`);
  }
  return response;
}

export async function listLocalArticles(scope: "all" | "published" = "published"): Promise<ArticleSummary[]> {
  const query = scope === "all" ? "?scope=all" : "";
  return localStorageResponse(`/api/articles${query}`).then((response) => response.json() as Promise<ArticleSummary[]>);
}

export async function getLocalArticle(slug: string, includeDraft = false): Promise<StoredArticle | null> {
  const query = includeDraft ? "?includeDraft=1" : "";
  const response = await fetch(new URL(`/api/articles/${encodeURIComponent(slug)}${query}`, localStorageOrigin()), {
    cache: "no-store",
  });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`Local storage request failed with status ${response.status}`);
  return response.json() as Promise<StoredArticle>;
}

export async function getLocalSiteSettings(): Promise<Record<string, unknown> | null> {
  return localStorageResponse("/api/site-settings").then((response) => response.json() as Promise<Record<string, unknown> | null>);
}

export async function listLocalActivity(since: string): Promise<ActivityDay[]> {
  const query = new URLSearchParams({ since });
  return localStorageResponse(`/api/activity?${query}`).then((response) => response.json() as Promise<ActivityDay[]>);
}

export function activityWindowStart(now = new Date()): string {
  const days = 365;
  const today = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  return new Date(today - (days - 1) * 24 * 60 * 60 * 1000).toISOString();
}

export async function proxyToLocalStorage(request: Request, pathname: string): Promise<Response> {
  const incomingURL = new URL(request.url);
  const target = new URL(`${pathname}${incomingURL.search}`, localStorageOrigin());
  const headers = new Headers(request.headers);
  headers.delete("connection");
  headers.delete("content-length");
  headers.delete("host");

  const init: RequestInit & { duplex?: "half" } = {
    body: request.method === "GET" || request.method === "HEAD" ? undefined : request.body,
    cache: "no-store",
    duplex: "half",
    headers,
    method: request.method,
    redirect: "manual",
  };
  const response = await fetch(target, init);
  const responseHeaders = new Headers(response.headers);
  responseHeaders.delete("access-control-allow-origin");
  responseHeaders.delete("access-control-expose-headers");
  responseHeaders.delete("vary");
  return new Response(response.body, {
    headers: responseHeaders,
    status: response.status,
    statusText: response.statusText,
  });
}
