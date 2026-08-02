export type ArticleStatus = "draft" | "published";

export type ArticleMedia = {
  kind: "image" | "video";
  name: string;
  size: number;
  url: string;
};

export type StoredArticle = {
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
