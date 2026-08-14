CREATE TABLE `activity_events` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`event_type` text NOT NULL,
	`author_user_id` text NOT NULL,
	`created_at` text NOT NULL,
	CONSTRAINT "activity_events_type_check" CHECK("activity_events"."event_type" IN ('article_published', 'article_edited', 'image_published'))
);
--> statement-breakpoint
CREATE INDEX `activity_events_created_at_idx` ON `activity_events` (`created_at`);