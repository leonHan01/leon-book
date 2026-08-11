import { sql } from "drizzle-orm";
import { check, index, integer, sqliteTable, text } from "drizzle-orm/sqlite-core";

export const articles = sqliteTable("articles", {
  slug: text("slug").primaryKey(),
  title: text("title").notNull(),
  body: text("body").notNull().default(""),
  excerpt: text("excerpt").notNull().default(""),
  category: text("category").notNull().default("Uncategorized"),
  tagsJson: text("tags_json").notNull().default("[]"),
  mediaJson: text("media_json").notNull().default("[]"),
  bannerJson: text("banner_json"),
  status: text("status", { enum: ["draft", "published"] }).notNull().default("draft"),
  wordCount: integer("word_count").notNull().default(0),
  authorUserId: text("author_user_id").notNull(),
  updatedBy: text("updated_by").notNull(),
  createdAt: text("created_at").notNull(),
  updatedAt: text("updated_at").notNull(),
  publishedAt: text("published_at"),
}, (table) => [
  check("articles_status_check", sql`${table.status} IN ('draft', 'published')`),
  check("articles_word_count_check", sql`${table.wordCount} >= 0`),
  index("articles_publication_idx").on(table.status, table.publishedAt, table.updatedAt),
  index("articles_updated_at_idx").on(table.updatedAt),
]);

export const siteSettings = sqliteTable("site_settings", {
  id: integer("id").primaryKey(),
  settingsJson: text("settings_json").notNull(),
  updatedAt: text("updated_at").notNull(),
  updatedBy: text("updated_by").notNull(),
}, (table) => [
  check("site_settings_singleton_check", sql`${table.id} = 1`),
]);

export const uploads = sqliteTable("uploads", {
  objectKey: text("object_key").primaryKey(),
  articleSlug: text("article_slug"),
  kind: text("kind", { enum: ["image", "video"] }).notNull(),
  originalName: text("original_name").notNull(),
  contentType: text("content_type").notNull(),
  byteSize: integer("byte_size").notNull(),
  authorUserId: text("author_user_id").notNull(),
  createdAt: text("created_at").notNull(),
}, (table) => [
  check("uploads_kind_check", sql`${table.kind} IN ('image', 'video')`),
  check("uploads_byte_size_check", sql`${table.byteSize} >= 0`),
  index("uploads_article_slug_idx").on(table.articleSlug, table.createdAt),
]);

export const deletionQueue = sqliteTable("deletion_queue", {
  objectKey: text("object_key").primaryKey(),
  articleSlug: text("article_slug").notNull(),
  createdAt: text("created_at").notNull(),
}, (table) => [
  index("deletion_queue_article_slug_idx").on(table.articleSlug, table.createdAt),
]);
