import type { MetadataRoute } from "next";
import { headers } from "next/headers";
import { listLocalArticles } from "../lib/server/local-storage";
import { requestOrigin } from "../lib/server/request-origin";

export const dynamic = "force-dynamic";

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const requestHeaders = await headers();
  const origin = requestOrigin(requestHeaders);
  const routes: MetadataRoute.Sitemap = [{
    url: origin.href,
    changeFrequency: "weekly",
    priority: 1,
  }];

  try {
    const articles = await listLocalArticles("published");
    routes.push(...articles.map((article) => ({
      url: new URL(`/article/${encodeURIComponent(article.slug)}`, origin).href,
      lastModified: article.updatedAt,
      changeFrequency: "monthly" as const,
      priority: 0.7,
    })));
  } catch {
    // Keep the homepage discoverable while a first-run database is unavailable.
  }

  return routes;
}
