CREATE TABLE `articles` (
	`slug` text PRIMARY KEY NOT NULL,
	`title` text NOT NULL,
	`body` text DEFAULT '' NOT NULL,
	`excerpt` text DEFAULT '' NOT NULL,
	`category` text DEFAULT 'Uncategorized' NOT NULL,
	`tags_json` text DEFAULT '[]' NOT NULL,
	`media_json` text DEFAULT '[]' NOT NULL,
	`banner_json` text,
	`status` text DEFAULT 'draft' NOT NULL,
	`word_count` integer DEFAULT 0 NOT NULL,
	`author_user_id` text NOT NULL,
	`updated_by` text NOT NULL,
	`created_at` text NOT NULL,
	`updated_at` text NOT NULL,
	`published_at` text,
	CONSTRAINT "articles_status_check" CHECK("articles"."status" IN ('draft', 'published')),
	CONSTRAINT "articles_word_count_check" CHECK("articles"."word_count" >= 0)
);
--> statement-breakpoint
CREATE INDEX `articles_publication_idx` ON `articles` (`status`,`published_at`,`updated_at`);--> statement-breakpoint
CREATE INDEX `articles_updated_at_idx` ON `articles` (`updated_at`);--> statement-breakpoint
CREATE TABLE `deletion_queue` (
	`object_key` text PRIMARY KEY NOT NULL,
	`article_slug` text NOT NULL,
	`created_at` text NOT NULL
);
--> statement-breakpoint
CREATE INDEX `deletion_queue_article_slug_idx` ON `deletion_queue` (`article_slug`,`created_at`);--> statement-breakpoint
CREATE TABLE `site_settings` (
	`id` integer PRIMARY KEY NOT NULL,
	`settings_json` text NOT NULL,
	`updated_at` text NOT NULL,
	`updated_by` text NOT NULL,
	CONSTRAINT "site_settings_singleton_check" CHECK("site_settings"."id" = 1)
);
--> statement-breakpoint
CREATE TABLE `uploads` (
	`object_key` text PRIMARY KEY NOT NULL,
	`article_slug` text,
	`kind` text NOT NULL,
	`original_name` text NOT NULL,
	`content_type` text NOT NULL,
	`byte_size` integer NOT NULL,
	`author_user_id` text NOT NULL,
	`created_at` text NOT NULL,
	CONSTRAINT "uploads_kind_check" CHECK("uploads"."kind" IN ('image', 'video')),
	CONSTRAINT "uploads_byte_size_check" CHECK("uploads"."byte_size" >= 0)
);
--> statement-breakpoint
CREATE INDEX `uploads_article_slug_idx` ON `uploads` (`article_slug`,`created_at`);
