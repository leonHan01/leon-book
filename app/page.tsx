import { env } from "cloudflare:workers";
import { headers } from "next/headers";
import HomeClient from "./home-client";
import type { ArticleSummary } from "./article-types";
import { DEFAULT_SITE_SETTINGS, normalizeSiteSettings } from "./site-settings";
import { createD1BlogRepository } from "../lib/server/blog-api";
import { isLocalRequestHeaders } from "../lib/server/request-origin";

export const dynamic = "force-dynamic";

export default async function HomePage() {
  let articles: ArticleSummary[] = [];
  let settings = DEFAULT_SITE_SETTINGS;
  let contentUnavailable = false;

  try {
    const requestHeaders = await headers();
    const repository = createD1BlogRepository(env.DB, {
      ensureSchema: env.BLOG_ALLOW_LOCAL_WRITES === "true" && isLocalRequestHeaders(requestHeaders),
    });
    const [storedArticles, storedSettings] = await Promise.all([
      repository.listArticles("published"),
      repository.getSiteSettings(),
    ]);
    articles = storedArticles;
    settings = normalizeSiteSettings(storedSettings);
  } catch {
    contentUnavailable = true;
  }

  return <HomeClient contentUnavailable={contentUnavailable} initialArticles={articles} initialSettings={settings} />;
}
