import type { MetadataRoute } from "next";
import { headers } from "next/headers";
import { requestOrigin } from "../lib/server/request-origin";

export const dynamic = "force-dynamic";

export default async function robots(): Promise<MetadataRoute.Robots> {
  const origin = requestOrigin(await headers());
  return {
    rules: {
      userAgent: "*",
      allow: "/",
      disallow: ["/api/", "/settings", "/upload", "/write", "/unauthorized"],
    },
    sitemap: new URL("/sitemap.xml", origin).href,
  };
}
