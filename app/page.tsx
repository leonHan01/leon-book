import HomeClient from "./home-client";
import type { ActivityDay } from "./activity-types";
import type { ArticleSummary } from "./article-types";
import { DEFAULT_SITE_SETTINGS, normalizeSiteSettings } from "./site-settings";
import {
  activityWindowStart,
  getLocalSiteSettings,
  listLocalActivity,
  listLocalArticles,
} from "../lib/server/local-storage";

export const dynamic = "force-dynamic";

export default async function HomePage() {
  let activity: ActivityDay[] = [];
  let articles: ArticleSummary[] = [];
  let settings = DEFAULT_SITE_SETTINGS;
  let contentUnavailable = false;

  try {
    const [storedArticles, storedSettings] = await Promise.all([
      listLocalArticles("published"),
      getLocalSiteSettings(),
    ]);
    articles = storedArticles;
    settings = normalizeSiteSettings(storedSettings);
  } catch {
    contentUnavailable = true;
  }

  try {
    activity = await listLocalActivity(activityWindowStart());
  } catch {
    // The archive remains readable if activity data is temporarily unavailable.
  }

  return <HomeClient activity={activity} contentUnavailable={contentUnavailable} initialArticles={articles} initialSettings={settings} />;
}
