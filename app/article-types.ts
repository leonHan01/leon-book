export type ArticleStatus = "draft" | "published";

export type ArticleMedia = {
  kind: "image" | "video";
  name: string;
  size: number;
  url: string;
};

export type ArticleBanner = {
  alt: string;
  name: string;
  size: number;
  url: string;
};

export type StoredArticle = {
  banner?: ArticleBanner;
  body: string;
  category: string;
  excerpt: string;
  media: ArticleMedia[];
  slug: string;
  status: ArticleStatus;
  tags: string[];
  title: string;
  updatedAt: string;
  publishedAt?: string;
};

export type ArticleSummary = Pick<
  StoredArticle,
  "banner" | "category" | "excerpt" | "publishedAt" | "slug" | "status" | "tags" | "title" | "updatedAt"
> & {
  wordCount: number;
};
