import type { ActivityDay } from "./activity-types";

type ActivityHeatmapProps = {
  activity: ActivityDay[];
  language: "en" | "zh";
};

const DAY_MS = 24 * 60 * 60 * 1000;

function dateKey(date: Date) {
  return date.toISOString().slice(0, 10);
}

function activityLevel(count: number) {
  if (count <= 0) return 0;
  if (count === 1) return 1;
  if (count === 2) return 2;
  if (count <= 4) return 3;
  return 4;
}

function calendarDays() {
  const today = new Date();
  const utcToday = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate()));
  const firstTrackedDay = new Date(utcToday.getTime() - 364 * DAY_MS);
  const firstCalendarDay = new Date(firstTrackedDay.getTime() - firstTrackedDay.getUTCDay() * DAY_MS);
  const days: Array<{ date: string; tracked: boolean }> = [];

  for (let day = firstCalendarDay; day <= utcToday; day = new Date(day.getTime() + DAY_MS)) {
    days.push({ date: dateKey(day), tracked: day >= firstTrackedDay });
  }
  return days;
}

export default function ActivityHeatmap({ activity, language }: ActivityHeatmapProps) {
  const text = language === "zh"
    ? {
      activity: "创作活动",
      legendLess: "少",
      legendMore: "多",
      summary: (count: number) => `过去一年共 ${count} 次创作活动`,
      title: (date: string, count: number) => `${date}：${count} 次创作活动`,
      weekdays: ["日", "一", "二", "三", "四", "五", "六"],
    }
    : {
      activity: "Creative activity",
      legendLess: "Less",
      legendMore: "More",
      summary: (count: number) => `${count} creative activities in the last year`,
      title: (date: string, count: number) => `${count} ${count === 1 ? "activity" : "activities"} on ${date}`,
      weekdays: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
    };
  const counts = new Map(
    activity
      .filter((day) => /^\d{4}-\d{2}-\d{2}$/.test(day.date) && Number.isFinite(day.count) && day.count > 0)
      .map((day) => [day.date, Math.floor(day.count)]),
  );
  const days = calendarDays();
  const total = [...counts.values()].reduce((sum, count) => sum + count, 0);

  return (
    <section className="activity-section wrap" aria-labelledby="activity-title">
      <div className="section-heading activity-heading">
        <div>
          <p className="eyebrow">{language === "zh" ? "创作记录" : "Creative record"}</p>
          <h2 id="activity-title">{text.activity}</h2>
        </div>
        <p className="section-note">{text.summary(total)}</p>
      </div>

      <div className="activity-card">
        <div className="activity-calendar-scroll">
          <div className="activity-weekdays" aria-hidden="true">
            {text.weekdays.map((day, index) => <span key={day}>{index % 2 === 1 ? day : ""}</span>)}
          </div>
          <div className="activity-calendar" role="grid" aria-label={text.activity}>
            {days.map((day) => {
              const count = day.tracked ? counts.get(day.date) ?? 0 : 0;
              const level = activityLevel(count);
              return (
                <span
                  aria-label={day.tracked ? text.title(day.date, count) : undefined}
                  aria-hidden={day.tracked ? undefined : true}
                  className={`activity-day level-${level}${day.tracked ? "" : " outside-range"}`}
                  key={day.date}
                  role={day.tracked ? "gridcell" : undefined}
                  title={day.tracked ? text.title(day.date, count) : undefined}
                />
              );
            })}
          </div>
        </div>
        <div className="activity-legend" aria-label={language === "zh" ? "活动频率颜色说明" : "Activity frequency color legend"}>
          <span>{text.legendLess}</span>
          {[0, 1, 2, 3, 4].map((level) => <i className={`activity-day level-${level}`} key={level} />)}
          <span>{text.legendMore}</span>
        </div>
      </div>
    </section>
  );
}
