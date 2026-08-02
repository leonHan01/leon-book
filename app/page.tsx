"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import type { StoredArticle } from "./article-types";
import {
  DEFAULT_SITE_SETTINGS,
  interfaceCopy,
  readSiteSettings,
  type SiteSettings,
} from "./site-settings";

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

const STORAGE_URL = "http://localhost:8787";

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

function articleToEntry(article: StoredArticle, language: "en" | "zh"): Entry {
  const image = article.media.find((media) => media.kind === "image");
  const wordCount = article.body.trim() ? article.body.trim().split(/\s+/).length : 0;
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
    imageAlt: image?.name || article.title,
    readTime: `${Math.max(1, Math.ceil(wordCount / 200))} ${language === "zh" ? "分钟阅读" : "min read"}`,
    slug: article.slug,
    tags: article.tags ?? [],
    title: article.title,
  };
}

export default function Home() {
  const [filter, setFilter] = useState("All");
  const [searchOpen, setSearchOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [publishedEntries, setPublishedEntries] = useState<Entry[]>([]);
  const [siteSettings, setSiteSettings] = useState<SiteSettings>(DEFAULT_SITE_SETTINGS);
  const text = interfaceCopy[siteSettings.language];

  useEffect(() => {
    // Local preferences are an external browser-side store; hydrate them after the first render.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setSiteSettings(readSiteSettings());
  }, []);

  useEffect(() => {
    document.documentElement.dataset.theme = siteSettings.theme;
  }, [siteSettings.theme]);

  useEffect(() => {
    let active = true;
    fetch(`${STORAGE_URL}/api/articles`)
      .then((response) => response.ok ? response.json() as Promise<StoredArticle[]> : [])
      .then((articles) => {
        if (!active || !Array.isArray(articles)) return;
        setPublishedEntries(articles.filter((article) => article.status === "published").map((article) => articleToEntry(article, siteSettings.language)));
      })
      .catch(() => {
        if (active) setPublishedEntries([]);
      });
    return () => { active = false; };
  }, [siteSettings.language]);

  const visibleEntries = useMemo(() => {
    const normalizedSearch = search.trim().toLowerCase();
    const sourceEntries = publishedEntries.length ? publishedEntries : entries;
    return sourceEntries.filter((entry) => {
      const matchesFilter = filter === "All" || entry.category === filter;
      const matchesSearch =
        !normalizedSearch ||
        `${entry.title} ${entry.excerpt} ${entry.category} ${(entry.tags ?? []).join(" ")}`
          .toLowerCase()
          .includes(normalizedSearch);
      return matchesFilter && matchesSearch;
    });
  }, [filter, publishedEntries, search]);

  const sourceEntries = publishedEntries.length ? publishedEntries : entries;
  const filters = useMemo(() => ["All", ...Array.from(new Set(sourceEntries.map((entry) => entry.category)))], [sourceEntries]);
  const featuredEntry = sourceEntries[0];
  const recentEntries = filter === "All" && !search.trim() ? visibleEntries.slice(1) : visibleEntries;

  return (
    <main className="site-shell">
      <header className="site-header">
        <a className="brand" href="#top" aria-label="Notebook 36 home">
          <span className="brand-mark">36</span>
          <span>
            <strong>Notebook</strong>
            <small>by Alex Rivera</small>
          </span>
        </a>

        <nav className="main-nav" aria-label="Primary navigation">
          <a className="active" href="#journal">
            {text.nav.journal}
          </a>
          <a href="#frames">{text.nav.frames}</a>
          <a href="#about">{text.nav.about}</a>
          <Link href="/settings">{text.nav.settings}</Link>
        </nav>

        <div className="header-actions">
          <button
            className="icon-button"
            type="button"
            aria-label="Search entries"
            aria-expanded={searchOpen}
            onClick={() => setSearchOpen((open) => !open)}
          >
            <span aria-hidden="true">⌕</span>
          </button>
          <Link className="write-button" href="/write">
            {text.nav.write} <span aria-hidden="true">↗</span>
          </Link>
        </div>
      </header>

      {searchOpen && (
        <div className="search-bar wrap">
            <label htmlFor="entry-search">{text.search}</label>
          <input
            id="entry-search"
            autoFocus
            value={search}
            onChange={(event) => setSearch(event.target.value)}
            placeholder={text.searchPlaceholder}
          />
          <button type="button" onClick={() => setSearch("")} aria-label="Clear search">
            ×
          </button>
        </div>
      )}

      <section className="hero wrap" id="top">
        <div className="hero-copy">
          <p className="eyebrow"><span /> Issue 07 · Spring / Summer 2025</p>
          <h1>
            Notes on making,
            <br />
            <em>noticing,</em> and staying curious.
          </h1>
          <p className="hero-intro">
            A personal field guide to creative work, everyday rituals, and the
            images that stay with us.
          </p>
          <a className="text-link" href="#journal">
            Read the latest <span aria-hidden="true">↓</span>
          </a>
        </div>

        <div className="hero-stamp" aria-label="Notebook 36 issue stamp">
          <div className="stamp-circle">N°<strong>36</strong></div>
          <p>WRITING<br />IMAGES<br />MOTION</p>
        </div>
      </section>

      <section className="featured wrap" id="journal">
        <div className="section-heading">
          <div>
            <p className="eyebrow">01 / Featured story</p>
            <h2>Start here</h2>
          </div>
          <p className="section-note">A longer thought for a slower moment.</p>
        </div>

        <article className="feature-card">
          <div className="feature-image">
            {featuredEntry.image ? <img src={featuredEntry.image} alt={featuredEntry.imageAlt} /> : <div className={`feature-color ${featuredEntry.accent}`}><span>✳</span></div>}
            <span className="image-label">Field note 01</span>
          </div>
          <div className="feature-content">
            <div className="entry-meta"><span>{featuredEntry.category}</span><span>{featuredEntry.date}</span></div>
            <h3>{featuredEntry.title}</h3>
            <p>{featuredEntry.excerpt}</p>
            {!!featuredEntry.tags?.length && <div className="entry-tags">{featuredEntry.tags.map((tag) => <span key={tag}>#{tag}</span>)}</div>}
            <div className="feature-footer">
              <span>{featuredEntry.readTime}</span>
              <a className="circle-arrow" href="#recent" aria-label="Read featured story">↗</a>
            </div>
          </div>
        </article>
      </section>

      <section className="recent wrap" id="recent">
        <div className="section-heading recent-heading">
          <div>
            <p className="eyebrow">02 / The notebook</p>
            <h2>Recent notes</h2>
          </div>
          <div className="filters" role="group" aria-label="Filter entries">
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
                  <img src={entry.image} alt={entry.imageAlt} />
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
                <a className="mini-link" href="#about">Keep reading <span aria-hidden="true">↗</span></a>
              </div>
            </article>
          ))}
        </div>
        {!recentEntries.length && <p className="empty-state">No notes found. Try another search.</p>}
      </section>

      <section className="frames-section" id="frames">
        <div className="wrap">
          <div className="section-heading frames-heading">
            <div>
              <p className="eyebrow">03 / Visual archive</p>
              <h2>Frames</h2>
            </div>
            <p className="section-note">A moving and still collection of things worth remembering.</p>
          </div>
          <div className="frames-grid">
            <figure className="frame-large">
              <img src="https://images.unsplash.com/photo-1500534623283-312aade485b7?auto=format&fit=crop&w=1400&q=90" alt="A quiet road through a green landscape" />
              <figcaption><span>01</span> Somewhere between here and there</figcaption>
            </figure>
            <figure className="frame-small frame-top">
              <img src="https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=900&q=85" alt="Sunlight over a misty hillside" />
              <figcaption><span>02</span> Morning light, remembered</figcaption>
            </figure>
            <figure className="frame-small frame-bottom">
              <img src="https://images.unsplash.com/photo-1518005020951-eccb494ad742?auto=format&fit=crop&w=900&q=85" alt="Abstract red architectural corner" />
              <figcaption><span>03</span> Geometry of a pause</figcaption>
            </figure>
            <div className="video-card">
              <div className="video-label"><span className="play-dot">▶</span><span>Motion study / 01</span></div>
              <video controls preload="metadata" poster="https://images.unsplash.com/photo-1470770841072-f978cf4d019e?auto=format&fit=crop&w=1200&q=85" aria-label="A short motion study of a meadow">
                <source src="https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4" type="video/mp4" />
                Your browser does not support the video tag.
              </video>
              <p>Let the image breathe.</p>
            </div>
          </div>
        </div>
      </section>

      <section className="about-section wrap" id="about">
        <div className="about-card">
          <div className="about-portrait" aria-hidden="true"><span>AR</span></div>
          <div className="about-copy">
            <p className="eyebrow">04 / About the author</p>
            <h2>Hi, I&apos;m Alex.<br /><em>I make room for ideas.</em></h2>
            <p>
              Writer, image-maker, and professional notice-taker. Notebook 36 is
              where I keep the threads: what I&apos;m learning, what I&apos;m looking at,
              and what I don&apos;t want to forget.
            </p>
            <a className="text-link" href="mailto:hello@notebook36.com">Say hello <span aria-hidden="true">↗</span></a>
          </div>
        </div>
      </section>

      <footer className="site-footer wrap">
        <div><span className="footer-mark">36</span><span>© 2025 Alex Rivera</span></div>
        <div className="footer-links"><a href="#top">Back to top ↑</a><a href="#about">Instagram</a><a href="mailto:hello@notebook36.com">Email</a></div>
      </footer>

    </main>
  );
}
