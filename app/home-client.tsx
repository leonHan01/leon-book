"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import type { ArticleSummary } from "./article-types";
import type { ActivityDay } from "./activity-types";
import ActivityHeatmap from "./activity-heatmap";
import {
  DEFAULT_SITE_SETTINGS,
  applySiteTheme,
  readSiteThemePreference,
  saveSiteThemePreference,
  type SiteSettings,
} from "./site-settings";
import ThemePicker from "./theme-picker";
import type { CSSProperties } from "react";
import { ContentImage } from "./content-image";

type Entry = {
  category: string;
  date: string;
  readTime?: string;
  title: string;
  excerpt: string;
  image?: string;
  imageAlt?: string;
  accent: string;
  slug?: string;
  tags?: string[];
};

type CSSVariables = {
  [name: `--${string}`]: string | number | undefined;
};

const entries: Entry[] = [
  {
    category: "Stories",
    date: "May 28, 2025",
    readTime: "8 min read",
    title: "The quiet craft of paying attention",
    excerpt:
      "On walking slower, collecting small signals, and making room for the detail that changes everything.",
    image:
      "https://images.unsplash.com/photo-1499750310107-5fef28a66643?auto=format&fit=crop&w=1500&q=90",
    imageAlt: "Notebook, coffee, and a camera on a wooden table",
    accent: "coral",
  },
  {
    category: "Stories",
    date: "May 12, 2025",
    readTime: "5 min read",
    title: "A room can be a compass",
    excerpt: "The spaces we return to quietly teach us what we value.",
    image:
      "https://images.unsplash.com/photo-1494438639946-1ebd1d20bf85?auto=format&fit=crop&w=1100&q=85",
    imageAlt: "Sunlit desk in a calm interior",
    accent: "sage",
  },
  {
    category: "Notes",
    date: "April 30, 2025",
    readTime: "3 min read",
    title: "In praise of unfinished lists",
    excerpt: "A list is not a contract. Sometimes it is just a place to keep the door open.",
    accent: "lavender",
  },
  {
    category: "Frames",
    date: "April 18, 2025",
    title: "Light studies / 04",
    excerpt: "A visual notebook from three late afternoons in the city.",
    image:
      "https://images.unsplash.com/photo-1493246507139-91e8fad9978e?auto=format&fit=crop&w=1100&q=85",
    imageAlt: "Hazy mountains in soft evening light",
    accent: "ink",
  },
  {
    category: "Notes",
    date: "April 04, 2025",
    readTime: "4 min read",
    title: "What I keep beside the bed",
    excerpt: "Three books, one pencil, and a question I am still learning how to ask.",
    accent: "butter",
  },
];

function articleToEntry(article: ArticleSummary, language: "en" | "zh"): Entry {
  const image = article.banner;
  const date = new Date(article.publishedAt ?? article.updatedAt);
  const formattedDate = Number.isNaN(date.getTime())
    ? article.updatedAt
    : date.toLocaleDateString(language === "zh" ? "zh-CN" : "en-US", { day: "2-digit", month: "short", year: "numeric" });
  return {
    accent: image ? "coral" : "lavender",
    category: article.category?.trim() || (language === "zh" ? "未分类" : "Uncategorized"),
    date: formattedDate,
    excerpt: article.excerpt || (language === "zh" ? "一篇刚刚发布的日志。" : "A newly published note from the notebook."),
    image: image?.url,
    imageAlt: image?.alt || article.title,
    readTime: `${Math.max(1, Math.ceil(article.wordCount / 200))} ${language === "zh" ? "分钟阅读" : "min read"}`,
    slug: article.slug,
    tags: article.tags ?? [],
    title: article.title,
  };
}

type HomeClientProps = {
  activity: ActivityDay[];
  contentUnavailable?: boolean;
  initialArticles: ArticleSummary[];
  initialSettings: SiteSettings;
};

export default function HomeClient({ activity, contentUnavailable = false, initialArticles, initialSettings }: HomeClientProps) {
  const [filter, setFilter] = useState("All");
  const [searchOpen, setSearchOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [siteSettings, setSiteSettings] = useState<SiteSettings>(initialSettings ?? DEFAULT_SITE_SETTINGS);
  const publishedEntries = useMemo(
    () => initialArticles
      .filter((article) => article.status === "published")
      .map((article) => articleToEntry(article, siteSettings.language)),
    [initialArticles, siteSettings.language],
  );
  const homeCopy = siteSettings.home.copy[siteSettings.language];
  const homeStyle = siteSettings.home.style;
  const fallbackEntries: Entry[] = siteSettings.home.fallbackEntries.length
    ? siteSettings.home.fallbackEntries
    : entries;
  const stylePalette = homeStyle.palette === "custom" ? {
    "--paper": homeStyle.paperColor,
    "--paper-deep": homeStyle.paperDeepColor,
    "--ink": homeStyle.inkColor,
    "--muted": homeStyle.mutedColor,
    "--line": homeStyle.lineColor,
    "--coral": homeStyle.accentColor,
  } : {};
  const serifFonts = {
    fraunces: '"Fraunces", Georgia, serif',
    georgia: "Georgia, serif",
    system: "ui-serif, Georgia, serif",
  } as const;
  const themedSerif = siteSettings.theme === "sketch"
    ? '"Caveat", "Ma Shan Zheng", cursive'
    : siteSettings.theme === "eink"
      ? '"DM Mono", ui-monospace, monospace'
      : serifFonts[homeStyle.serifFont];
  const spaceScale = { compact: "0.78", comfortable: "1", airy: "1.24" }[homeStyle.sectionSpacing];
  const headingScale = { compact: "0.86", standard: "1", display: "1.16" }[homeStyle.headingScale];
  const bodyScale = { compact: "0.92", standard: "1", large: "1.1" }[homeStyle.bodyScale];
  const homePageStyle: CSSProperties & CSSVariables = {
    ...stylePalette,
    "--serif": themedSerif,
    "--home-content-width": `${homeStyle.contentWidth}px`,
    "--home-side-padding": `${homeStyle.sidePadding}px`,
    "--home-header-height": `${homeStyle.headerHeight}px`,
    "--home-space-scale": spaceScale,
    "--home-heading-scale": headingScale,
    "--home-body-scale": bodyScale,
    "--home-notes-columns": String(homeStyle.notesColumns),
    "--home-radius": homeStyle.cornerStyle === "soft" ? "18px" : "var(--theme-radius)",
  };

  useEffect(() => {
    const preferredTheme = readSiteThemePreference();
    if (!preferredTheme || preferredTheme === initialSettings.theme) return;
    // A visitor's theme is device-local; site content and layout stay server-owned.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setSiteSettings((current) => ({ ...current, theme: preferredTheme }));
  }, [initialSettings.theme]);

  useEffect(() => {
    applySiteTheme(siteSettings.theme);
  }, [siteSettings.theme]);

  const changeTheme = (theme: SiteSettings["theme"]) => {
    const updated = { ...siteSettings, theme };
    setSiteSettings(updated);
    saveSiteThemePreference(theme);
    applySiteTheme(theme);
  };

  const visibleEntries = useMemo(() => {
    const normalizedSearch = search.trim().toLowerCase();
    const sourceEntries = publishedEntries.length ? publishedEntries : fallbackEntries;
    return sourceEntries.filter((entry) => {
      const matchesFilter = filter === "All" || entry.category === filter;
      const matchesSearch =
        !normalizedSearch ||
        `${entry.title} ${entry.excerpt} ${entry.category} ${(entry.tags ?? []).join(" ")}`
          .toLowerCase()
          .includes(normalizedSearch);
      return matchesFilter && matchesSearch;
    });
  }, [fallbackEntries, filter, publishedEntries, search]);

  const sourceEntries = publishedEntries.length ? publishedEntries : fallbackEntries;
  const filters = useMemo(() => ["All", ...Array.from(new Set(sourceEntries.map((entry) => entry.category)))], [sourceEntries]);
  const featuredEntry = sourceEntries[0];
  const featuredHref = featuredEntry.slug ? `/article/${encodeURIComponent(featuredEntry.slug)}` : "#recent";
  const recentEntries = filter === "All" && !search.trim() ? visibleEntries.slice(1) : visibleEntries;

  return (
    <main className="site-shell" style={homePageStyle}>
      {contentUnavailable && <p className="empty-state" role="status">The published archive is temporarily unavailable.</p>}
      <header className="site-header">
        <a className="brand" href="#top" aria-label={`${homeCopy.brandName} home`}>
          <span className="brand-mark">{homeCopy.brandMark}</span>
          <span>
            <strong>{homeCopy.brandName}</strong>
            <small>{homeCopy.brandSubtitle}</small>
          </span>
        </a>

        <nav className="main-nav" aria-label={homeCopy.navJournal}>
          <a className="active" href="#journal">
            {homeCopy.navJournal}
          </a>
          <a href="#frames">{homeCopy.navFrames}</a>
          <Link href="/upload">{siteSettings.language === "zh" ? "影像上传" : "Image upload"}</Link>
          <a href="#about">{homeCopy.navAbout}</a>
          <Link href="/settings">{homeCopy.navSettings}</Link>
        </nav>

        <div className="header-actions">
          <ThemePicker language={siteSettings.language} value={siteSettings.theme} compact onChange={changeTheme} />
          <button
            className="icon-button"
            type="button"
            aria-label={homeCopy.searchAria}
            aria-expanded={searchOpen}
            onClick={() => setSearchOpen((open) => !open)}
          >
            <span aria-hidden="true">⌕</span>
          </button>
          <Link className="write-button" href="/write">
            {homeCopy.navWrite} <span aria-hidden="true">↗</span>
          </Link>
        </div>
      </header>

      {searchOpen && (
        <div className="search-bar wrap">
            <label htmlFor="entry-search">{homeCopy.searchLabel}</label>
          <input
            id="entry-search"
            autoFocus
            value={search}
            onChange={(event) => setSearch(event.target.value)}
            placeholder={homeCopy.searchPlaceholder}
          />
          <button type="button" onClick={() => setSearch("")} aria-label={homeCopy.clearSearchAria}>
            ×
          </button>
        </div>
      )}

      <section className={`hero wrap ${homeStyle.heroLayout === "stacked" ? "hero-stacked" : ""}`} id="top">
        <div className="hero-copy">
          <p className="eyebrow"><span /> {homeCopy.issueLabel}</p>
          <h1>
            {homeCopy.heroTitleLead}
            <br />
            <em>{homeCopy.heroTitleEmphasis}</em> {homeCopy.heroTitleTail}
          </h1>
          <p className="hero-intro">{homeCopy.heroIntro}</p>
          <a className="text-link" href="#journal">
            {homeCopy.heroCta} <span aria-hidden="true">↓</span>
          </a>
        </div>

        <div className="hero-stamp" aria-label={`${homeCopy.brandName} issue stamp`}>
          <div className="stamp-circle">N°<strong>{homeCopy.heroStampNumber}</strong></div>
          <p>{homeCopy.heroStampLines.split("\n").map((line) => <span key={line}>{line}<br /></span>)}</p>
        </div>
      </section>

      {homeStyle.showFeatured && <section className="featured wrap" id="journal">
        <div className="section-heading">
          <div>
            <p className="eyebrow">{homeCopy.featuredKicker}</p>
            <h2>{homeCopy.featuredTitle}</h2>
          </div>
          <p className="section-note">{homeCopy.featuredNote}</p>
        </div>

        <article className="feature-card">
          <div className="feature-image">
            {featuredEntry.image ? <ContentImage src={featuredEntry.image} alt={featuredEntry.imageAlt ?? featuredEntry.title} priority /> : <div className={`feature-color ${featuredEntry.accent}`}><span>✳</span></div>}
            <span className="image-label">{homeCopy.featuredImageLabel}</span>
          </div>
          <div className="feature-content">
            <div className="entry-meta"><span>{featuredEntry.category}</span><span>{featuredEntry.date}</span></div>
            <h3>{featuredEntry.slug ? <Link href={featuredHref}>{featuredEntry.title}</Link> : featuredEntry.title}</h3>
            <p>{featuredEntry.excerpt}</p>
            {!!featuredEntry.tags?.length && <div className="entry-tags">{featuredEntry.tags.map((tag) => <span key={tag}>#{tag}</span>)}</div>}
            <div className="feature-footer">
              <span>{featuredEntry.readTime}</span>
              <Link className="circle-arrow" href={featuredHref} aria-label={homeCopy.featuredReadAria}>↗</Link>
            </div>
          </div>
        </article>
      </section>}

      {homeStyle.showRecent && <section className="recent wrap" id="recent">
        <div className="section-heading recent-heading">
          <div>
            <p className="eyebrow">{homeCopy.recentKicker}</p>
            <h2>{homeCopy.recentTitle}</h2>
          </div>
          <div className="filters" role="group" aria-label={homeCopy.recentFilterAria}>
            {filters.map((item) => (
              <button
                key={item}
                type="button"
                className={filter === item ? "selected" : ""}
                onClick={() => setFilter(item)}
              >
                {item}
              </button>
            ))}
          </div>
        </div>

        <div className="notes-grid">
          {recentEntries.map((entry, index) => (
            <article className={`note-card ${entry.image ? "has-image" : "text-only"}`} key={`${entry.slug ?? entry.title}-${entry.date}`}>
              {entry.image ? (
                <div className={`note-image ${entry.accent}`}>
                  <ContentImage src={entry.image} alt={entry.imageAlt ?? entry.title} />
                  <span>{String(index + 2).padStart(2, "0")}</span>
                </div>
              ) : (
                <div className={`note-color ${entry.accent}`}><span>✳</span></div>
              )}
              <div className="note-card-content">
                <div className="entry-meta"><span>{entry.category}</span><span>{entry.date}</span></div>
                <h3>{entry.title}</h3>
                <p>{entry.excerpt}</p>
                {!!entry.tags?.length && <div className="entry-tags">{entry.tags.map((tag) => <span key={tag}>#{tag}</span>)}</div>}
                <Link className="mini-link" href={entry.slug ? `/article/${encodeURIComponent(entry.slug)}` : "#about"}>{homeCopy.recentReadMore} <span aria-hidden="true">↗</span></Link>
              </div>
            </article>
          ))}
        </div>
        {!recentEntries.length && <p className="empty-state">{homeCopy.recentEmpty}</p>}
      </section>}

      <ActivityHeatmap activity={activity} language={siteSettings.language} />

      {homeStyle.showFrames && <section className="frames-section" id="frames">
        <div className="wrap">
          <div className="section-heading frames-heading">
            <div>
              <p className="eyebrow">{homeCopy.framesKicker}</p>
              <h2>{homeCopy.framesTitle}</h2>
            </div>
            <p className="section-note">{homeCopy.framesNote}</p>
          </div>
          <div className={`frames-grid ${homeStyle.framesLayout === "stacked" ? "frames-stacked" : ""}`}>
            <figure className="frame-large">
              <ContentImage src={siteSettings.home.frames[0].imageUrl} alt={siteSettings.home.frames[0].imageAlt} />
              <figcaption><span>01</span> {siteSettings.home.frames[0].caption}</figcaption>
            </figure>
            <figure className="frame-small frame-top">
              <ContentImage src={siteSettings.home.frames[1].imageUrl} alt={siteSettings.home.frames[1].imageAlt} />
              <figcaption><span>02</span> {siteSettings.home.frames[1].caption}</figcaption>
            </figure>
            <figure className="frame-small frame-bottom">
              <ContentImage src={siteSettings.home.frames[2].imageUrl} alt={siteSettings.home.frames[2].imageAlt} />
              <figcaption><span>03</span> {siteSettings.home.frames[2].caption}</figcaption>
            </figure>
            <div className="video-card">
              <div className="video-label"><span className="play-dot">▶</span><span>{homeCopy.motionLabel}</span></div>
              <video controls preload="metadata" poster={siteSettings.home.motion.posterUrl} aria-label={homeCopy.motionAria}>
                <source src={siteSettings.home.motion.videoUrl} type="video/mp4" />
                Your browser does not support the video tag.
              </video>
              <p>{homeCopy.motionCaption}</p>
            </div>
          </div>
        </div>
      </section>}

      {homeStyle.showAbout && <section className="about-section wrap" id="about">
        <div className="about-card">
          <div className="about-portrait" aria-hidden="true"><span>AR</span></div>
          <div className="about-copy">
            <p className="eyebrow">{homeCopy.aboutKicker}</p>
            <h2>{homeCopy.aboutTitleLead}<br /><em>{homeCopy.aboutTitleEmphasis}</em></h2>
            <p>{homeCopy.aboutBio}</p>
            <a className="text-link" href={`mailto:${homeCopy.contactEmail}`}>{homeCopy.aboutCta} <span aria-hidden="true">↗</span></a>
          </div>
        </div>
      </section>}

      {homeStyle.showFooter && <footer className="site-footer wrap">
        <div><span className="footer-mark">{homeCopy.brandMark}</span><span>{homeCopy.footerCopyright}</span></div>
        <div className="footer-links"><a href="#top">{homeCopy.footerBackToTop}</a><a href="#about">{homeCopy.footerInstagram}</a><a href={`mailto:${homeCopy.contactEmail}`}>{homeCopy.footerEmail}</a></div>
      </footer>}

    </main>
  );
}
