import { useMemo, useState } from "react";
import { useStore } from "../data/store";
import { useClock } from "../data/clock";
import {
  nextDay,
  overlapWithinMs,
  startOfDay,
  startOfMonth,
  startOfWeek,
} from "../models/timeMath";
import type { Member } from "../models/member";
import type { TimeEntry } from "../models/timeEntry";
import "./dashboard.css";

/* Port of dashboard_screen.dart: today's split, a weekly recap, and a
 * filterable log.
 *
 * The arithmetic is the part that matters and it is already ported —
 * `overlapWithinMs` SLICES an entry across the window rather than bucketing it
 * by its start, so a session that runs 23:40 to 00:20 puts twenty minutes in
 * each day rather than forty in one. It also goes through `effectiveEnd`, so a
 * timer somebody forgot cannot inflate a day, a week or a total.
 *
 * The one visual departure from the Dart, for the reason in tokens.css: bars
 * are split by member colour, and every bar is ALSO labelled. The Dart's own
 * comment says identity must never be carried by colour alone; these hues fail
 * contrast against the page, so the legend and the row labels are the real
 * signal and the colour is the shortcut.
 */

type Period = "today" | "week" | "month" | "all";

const PERIOD_LABEL: Record<Period, string> = {
  today: "Today",
  week: "This week",
  month: "This month",
  all: "All time",
};

/** The four windows, exactly as LogPeriod.window does it in the Dart. */
function windowFor(p: Period, now: Date): [Date, Date] {
  switch (p) {
    case "today": return [startOfDay(now), nextDay(now)];
    case "week": return [startOfWeek(now), nextDay(now)];
    case "month": return [startOfMonth(now), nextDay(now)];
    case "all": return [new Date(0), nextDay(now)];
  }
}

function fmtTotal(ms: number): string {
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const mins = Math.floor(s / 60);
  if (mins < 60) return `${mins}m`;
  const m = mins % 60;
  return m === 0 ? `${Math.floor(mins / 60)}h` : `${Math.floor(mins / 60)}h ${m}m`;
}

const clock = (d: Date) =>
  `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;

const dayName = (d: Date) => d.toLocaleDateString(undefined, { weekday: "short" });
const monthDay = (d: Date) => d.toLocaleDateString(undefined, { month: "short", day: "numeric" });

/** A bar split into one segment per member, sized against the longest bar. */
function SplitBar({
  split,
  members,
  maxMs,
}: {
  split: Map<string, number>;
  members: Member[];
  maxMs: number;
}) {
  const total = [...split.values()].reduce((a, b) => a + b, 0);
  if (maxMs <= 0) return <span className="bar" />;
  return (
    <span className="bar" style={{ inlineSize: `${(total / maxMs) * 100}%` }}>
      {members.map((m) => {
        const ms = split.get(m.id) ?? 0;
        if (ms <= 0) return null;
        return (
          <span
            key={m.id}
            className="bar-seg"
            style={{
              ["--member" as string]: m.color || "var(--ink-3)",
              flexGrow: ms,
            }}
          />
        );
      })}
    </span>
  );
}

export function Dashboard() {
  const s = useStore();
  /* Once a minute, not once a second.
   *
   * Nothing on this page is shown to the second — the smallest unit anywhere is
   * "17m" — so projecting the clock to whole minutes means a live entry
   * re-renders the dashboard sixty times less often than the board's ticking
   * digits do, for a display that is identical either way.
   *
   * Memoised on the minute number rather than rebuilt each render, because
   * `now` is a dependency of every aggregate below; a fresh Date each render
   * would recompute all of them every time anything at all changed. */
  const minute = useClock((t) => Math.floor(t / 60_000));
  const now = useMemo(() => new Date(minute * 60_000), [minute]);

  const [period, setPeriod] = useState<Period>("today");
  const [memberFilter, setMemberFilter] = useState<string | null>(null);
  const [taskFilter, setTaskFilter] = useState<string | null>(null);

  const taskById = useMemo(() => new Map(s.tasks.map((t) => [t.id, t])), [s.tasks]);
  const workById = useMemo(() => new Map(s.works.map((w) => [w.id, w])), [s.works]);
  const memberById = useMemo(() => new Map(s.members.map((m) => [m.id, m])), [s.members]);

  /* First-touch order, so the legend and every bar agree on which colour sits
   * where. Members with no time at all fall to the end. */
  const ordered = useMemo(() => {
    const seen: string[] = [];
    for (const e of s.entries) if (!seen.includes(e.memberId)) seen.push(e.memberId);
    const known = seen.map((id) => memberById.get(id)).filter((m): m is Member => !!m);
    const rest = s.members.filter((m) => !seen.includes(m.id));
    return [...known, ...rest];
  }, [s.entries, s.members, memberById]);

  /* ---- today ------------------------------------------------------------ */
  const today = useMemo(() => {
    const from = startOfDay(now);
    const to = nextDay(now);
    const byWork = new Map<string, Map<string, number>>();
    const byMember = new Map<string, number>();
    let total = 0;

    for (const e of s.entries) {
      const ms = overlapWithinMs(e, from, to, now);
      if (ms <= 0) continue;
      const task = taskById.get(e.taskId);
      if (!task) continue;
      total += ms;
      byMember.set(e.memberId, (byMember.get(e.memberId) ?? 0) + ms);
      let w = byWork.get(task.workId);
      if (!w) { w = new Map(); byWork.set(task.workId, w); }
      w.set(e.memberId, (w.get(e.memberId) ?? 0) + ms);
    }

    /* Only Works touched today. With a daily window most Works are zero, and a
     * page of empty tracks buries the ones that moved. */
    const rows = [...byWork.entries()]
      .map(([workId, split]) => ({
        workId,
        title: workById.get(workId)?.title ?? "Deleted work",
        split,
        total: [...split.values()].reduce((a, b) => a + b, 0),
      }))
      .sort((a, b) => b.total - a.total);

    return { total, byMember, rows, maxMs: rows.length ? rows[0].total : 0 };
  }, [s.entries, taskById, workById, now]);

  /* ---- the week --------------------------------------------------------- */
  const week = useMemo(() => {
    const monday = startOfWeek(now);
    const days = Array.from({ length: 7 }, (_, i) =>
      new Date(monday.getFullYear(), monday.getMonth(), monday.getDate() + i));
    const splits = days.map(() => new Map<string, number>());
    const totals = days.map(() => 0);
    let total = 0;

    for (let i = 0; i < 7; i++) {
      const from = days[i];
      const to = nextDay(from);
      for (const e of s.entries) {
        const ms = overlapWithinMs(e, from, to, now);
        if (ms <= 0) continue;
        totals[i] += ms;
        total += ms;
        splits[i].set(e.memberId, (splits[i].get(e.memberId) ?? 0) + ms);
      }
    }
    return { days, splits, totals, total, maxMs: Math.max(0, ...totals) };
  }, [s.entries, now]);

  /* ---- the log ---------------------------------------------------------- */
  const log = useMemo(() => {
    const [from, to] = windowFor(period, now);
    return s.entries
      .filter((e) => overlapWithinMs(e, from, to, now) > 0)
      .filter((e) => (memberFilter === null ? true : e.memberId === memberFilter))
      .filter((e) => (taskFilter === null ? true : e.taskId === taskFilter))
      .slice()
      .sort((a, b) => b.startedAt.getTime() - a.startedAt.getTime());
  }, [s.entries, period, memberFilter, taskFilter, now]);

  const todayStart = startOfDay(now);

  return (
    <main className="dash">
      <section>
        <p className="label">Where our effort went today</p>
        <p className="dash-big tnum">{fmtTotal(today.total)}</p>
        <p className="dash-sub">
          {today.rows.length === 0
            ? now.toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "long" })
            : `tracked across ${today.rows.length} work${today.rows.length === 1 ? "" : "s"} today`}
        </p>

        {today.rows.length === 0 ? (
          <p className="quiet">
            Nothing tracked today yet — press Start on a task on the Board.
          </p>
        ) : (
          <>
            {/* Names and totals, so identity is never carried by colour alone. */}
            <ul className="legend">
              {ordered.map((m) => {
                const ms = today.byMember.get(m.id) ?? 0;
                if (ms <= 0) return null;
                return (
                  <li key={m.id} style={{ ["--member" as string]: m.color || "var(--ink-3)" }}>
                    <span className="member-dot" />
                    <span className="legend-name">{m.name}</span>
                    <span className="tnum legend-total">{fmtTotal(ms)}</span>
                  </li>
                );
              })}
            </ul>

            <ul className="workbars">
              {today.rows.map((r) => (
                <li key={r.workId}>
                  <span className="workbar-head">
                    <span className="workbar-title">{r.title}</span>
                    <span className="tnum workbar-total">{fmtTotal(r.total)}</span>
                  </span>
                  <SplitBar split={r.split} members={ordered} maxMs={today.maxMs} />
                </li>
              ))}
            </ul>
          </>
        )}
      </section>

      <hr className="rule" />

      <section>
        <div className="section-head">
          <p className="label">This week</p>
          <span className="tnum section-total">{fmtTotal(week.total)}</span>
        </div>
        <p className="dash-sub">
          {monthDay(week.days[0])} – {monthDay(week.days[6])}
        </p>

        <ul className="week">
          {week.days.map((d, i) => {
            const isToday = d.getTime() === todayStart.getTime();
            const isFuture = d.getTime() > todayStart.getTime();
            return (
              <li key={d.toISOString()} className={isToday ? "is-today" : isFuture ? "is-future" : ""}>
                <span className="week-day">{dayName(d)}</span>
                <SplitBar split={week.splits[i]} members={ordered} maxMs={week.maxMs} />
                <span className="tnum week-total">
                  {week.totals[i] > 0 ? fmtTotal(week.totals[i]) : ""}
                </span>
              </li>
            );
          })}
        </ul>
      </section>

      <hr className="rule" />

      <section>
        <div className="section-head">
          <p className="label">The log</p>
          <span className="tnum section-total">
            {log.length} entr{log.length === 1 ? "y" : "ies"}
          </span>
        </div>

        <div className="filters">
          <select
            value={period}
            onChange={(e) => setPeriod(e.target.value as Period)}
            aria-label="Period"
          >
            {(Object.keys(PERIOD_LABEL) as Period[]).map((p) => (
              <option key={p} value={p}>{PERIOD_LABEL[p]}</option>
            ))}
          </select>

          <select
            value={memberFilter ?? ""}
            onChange={(e) => setMemberFilter(e.target.value || null)}
            aria-label="Who"
          >
            <option value="">Everyone</option>
            {s.members.map((m) => (
              <option key={m.id} value={m.id}>{m.name}</option>
            ))}
          </select>

          <select
            value={taskFilter ?? ""}
            onChange={(e) => setTaskFilter(e.target.value || null)}
            aria-label="Task"
          >
            <option value="">Any task</option>
            {s.tasks.map((t) => (
              <option key={t.id} value={t.id}>{t.title}</option>
            ))}
          </select>
        </div>

        {log.length === 0 ? (
          <p className="quiet">No entries match these filters.</p>
        ) : (
          <ul className="log">
            {log.map((e) => (
              <LogRow
                key={e.id}
                entry={e}
                taskTitle={taskById.get(e.taskId)?.title ?? "Deleted task"}
                workTitle={
                  workById.get(taskById.get(e.taskId)?.workId ?? "")?.title ?? null
                }
                member={memberById.get(e.memberId) ?? null}
                now={now}
              />
            ))}
          </ul>
        )}
      </section>
    </main>
  );
}

function LogRow({
  entry,
  taskTitle,
  workTitle,
  member,
  now,
}: {
  entry: TimeEntry;
  taskTitle: string;
  workTitle: string | null;
  member: Member | null;
  now: Date;
}) {
  const live = entry.endedAt === null;
  const span = live
    ? `${clock(entry.startedAt)} → now`
    : `${clock(entry.startedAt)} → ${clock(entry.endedAt!)}`;
  /* The whole entry, not the slice inside the current window — the log is a
   * list of sessions, and a session that straddles midnight is still one
   * session. The windowing above decides which rows appear, not how long they
   * were. */
  const ms = overlapWithinMs(entry, entry.startedAt, nextDay(now), now);

  return (
    <li style={{ ["--member" as string]: member?.color || "var(--ink-3)" }}>
      <span className="member-bar" />
      <span className="log-body">
        <span className="log-title">{taskTitle}</span>
        <span className="log-meta">
          {member?.name ?? "someone"}
          {workTitle && <> · {workTitle}</>} · {span}
        </span>
      </span>
      {live && <span className="log-live">live</span>}
      <span className="tnum log-total">{fmtTotal(ms)}</span>
    </li>
  );
}
