import type { Metadata } from "next";
import { headers } from "next/headers";
import { getLocalSiteSettings } from "../lib/server/local-storage";
import { requestOrigin } from "../lib/server/request-origin";
import { DEFAULT_SITE_SETTINGS, normalizeSiteSettings } from "./site-settings";
import "./globals.css";

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const metadataBase = requestOrigin(requestHeaders);

  return {
    metadataBase,
    title: "Notebook 36 — Alex Rivera",
    description: "A personal field guide to creative work, everyday rituals, and the images that stay with us.",
    openGraph: {
      title: "Notebook 36 — Alex Rivera",
      description: "Writing, images, and motion by Alex Rivera.",
      type: "website",
      images: [{ url: "/og-notebook36.jpg", width: 1200, height: 630, alt: "Notebook 36 editorial social preview" }],
    },
    twitter: {
      card: "summary_large_image",
      title: "Notebook 36 — Alex Rivera",
      description: "Writing, images, and motion by Alex Rivera.",
      images: ["/og-notebook36.jpg"],
    },
    icons: { icon: "/favicon.svg", shortcut: "/favicon.svg" },
  };
}

export default async function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  let siteSettings = DEFAULT_SITE_SETTINGS;
  try {
    siteSettings = normalizeSiteSettings(await getLocalSiteSettings());
  } catch {
    // The default language keeps build probes and first-run local rendering usable.
  }

  return (
    <html lang={siteSettings.language === "zh" ? "zh-CN" : "en"} suppressHydrationWarning>
      <head>
        <script
          dangerouslySetInnerHTML={{
            __html: `(() => { try { const saved = JSON.parse(localStorage.getItem("notebook36-settings") || "null"); const themes = ["paper", "night", "sunset", "forest", "ocean", "mono", "sketch", "eink", "system"]; const theme = themes.includes(saved?.theme) ? saved.theme : ${JSON.stringify(siteSettings.theme)}; document.documentElement.dataset.theme = theme; } catch (_) { document.documentElement.dataset.theme = ${JSON.stringify(siteSettings.theme)}; } })();`,
          }}
        />
      </head>
      <body>{children}</body>
    </html>
  );
}
