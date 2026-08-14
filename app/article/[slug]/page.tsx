import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { cache, type ReactNode } from "react";
import { ContentImage } from "../../content-image";
import { getLocalArticle, getLocalSiteSettings } from "../../../lib/server/local-storage";
import type { StoredArticle } from "../../article-types";
import { renderMarkdown } from "../../markdown-renderer";
import { normalizeSiteSettings, type SiteLanguage } from "../../site-settings";

export const dynamic = "force-dynamic";

type ArticlePageProps = {
  params: Promise<{ slug: string }>;
};

const loadArticle = cache(async (slug: string) => {
  return getLocalArticle(slug, false);
});

const loadLanguage = cache(async (): Promise<SiteLanguage> => {
  try {
    return normalizeSiteSettings(await getLocalSiteSettings()).language;
  } catch {
    return "en";
  }
});

function formatDate(value: string, language: SiteLanguage) {
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? value
    : date.toLocaleDateString(language === "zh" ? "zh-CN" : "en-US", {
        day: "2-digit",
        month: "short",
        year: "numeric",
      });
}

function renderArticleBody(article: StoredArticle): ReactNode {
  const nodes: ReactNode[] = [];
  const body = article.body ?? "";
  const mediaPattern = /!\[([^\]]*)\]\(([^)\s]+)\)|<video\s+controls\s+src="([^"]+)"\s*><\/video>/g;
  let cursor = 0;
  let nodeIndex = 0;
  let match: RegExpExecArray | null;

  while ((match = mediaPattern.exec(body))) {
    const textBefore = body.slice(cursor, match.index).replace(/^\n+|\n+$/g, "");
    if (textBefore.trim()) {
      nodes.push(
        <div className="article-detail-copy preview-copy" key={`copy-${nodeIndex++}`}>
          {renderMarkdown(textBefore, "")}
        </div>,
      );
    }

    const isImage = match[1] !== undefined;
    const source = match[2] ?? match[3];
    const storedMedia = article.media?.find((media) => media.url === source);
    const name = storedMedia?.name ?? match[1] ?? (isImage ? "Image" : "Video");
    nodes.push(
      isImage ? (
        <figure className="article-detail-media" key={`media-${nodeIndex++}`}>
          <ContentImage src={source} alt={name} />
          <figcaption>{name}</figcaption>
        </figure>
      ) : (
        <figure className="article-detail-media" key={`media-${nodeIndex++}`}>
          <video src={source} controls playsInline preload="metadata" />
          <figcaption>{name}</figcaption>
        </figure>
      ),
    );
    cursor = match.index + match[0].length;
  }

  const textAfter = body.slice(cursor).replace(/^\n+|\n+$/g, "");
  if (textAfter.trim()) {
    nodes.push(
      <div className="article-detail-copy preview-copy" key={`copy-${nodeIndex++}`}>
        {renderMarkdown(textAfter, "")}
      </div>,
    );
  }
  return nodes.length ? nodes : <p className="preview-placeholder">No content yet.</p>;
}

export async function generateMetadata({ params }: ArticlePageProps): Promise<Metadata> {
  const { slug } = await params;
  const article = await loadArticle(slug).catch(() => null);
  if (!article) return { title: "Article not found · Notebook 36" };

  return {
    title: `${article.title} · Notebook 36`,
    description: article.excerpt || undefined,
    openGraph: {
      type: "article",
      title: article.title,
      description: article.excerpt || undefined,
      publishedTime: article.publishedAt,
      modifiedTime: article.updatedAt,
      images: article.banner ? [{ url: article.banner.url, alt: article.banner.alt || article.title }] : undefined,
    },
  };
}

export default async function ArticlePage({ params }: ArticlePageProps) {
  const { slug } = await params;
  const [article, language] = await Promise.all([
    loadArticle(slug).catch(() => null),
    loadLanguage(),
  ]);
  if (!article) notFound();

  const copy = language === "zh"
    ? { back: "返回首页", edit: "编辑文章", empty: "暂无正文" }
    : { back: "Back home", edit: "Edit article", empty: "No content yet" };

  return (
    <main className="article-page">
      <header className="site-header article-page-header">
        <Link className="brand" href="/" aria-label="Notebook 36 home">
          <span className="brand-mark">36</span>
          <span><strong>Notebook</strong><small>by Alex Rivera</small></span>
        </Link>
        <Link className="settings-back" href="/">← {copy.back}</Link>
      </header>

      <article className="article-detail">
        <div className="article-detail-kicker">
          <span>{article.category}</span>
          <time dateTime={article.publishedAt ?? article.updatedAt}>
            {formatDate(article.publishedAt ?? article.updatedAt, language)}
          </time>
        </div>
        <h1>{article.title}</h1>
        {article.excerpt && <p className="article-detail-excerpt">{article.excerpt}</p>}
        {!!article.tags?.length && (
          <div className="entry-tags article-detail-tags">
            {article.tags.map((tag) => <span key={tag}>#{tag}</span>)}
          </div>
        )}
        {article.banner && (
          <figure className="article-detail-banner">
            <ContentImage src={article.banner.url} alt={article.banner.alt || article.title} priority />
          </figure>
        )}
        <div className="article-detail-body">{renderArticleBody(article) || copy.empty}</div>
        <div className="article-detail-footer">
          <Link className="text-link" href="/">← {copy.back}</Link>
          <Link className="text-link" href={`/write?slug=${encodeURIComponent(article.slug)}`}>
            {copy.edit} <span aria-hidden="true">↗</span>
          </Link>
        </div>
      </article>
    </main>
  );
}
