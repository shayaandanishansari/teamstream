import { useEffect, useMemo, useState } from "react";
import { useStore } from "../data/store";
import { useDepartures } from "./useDepartures";
import { useClock } from "../data/clock";
import { MenuButton, MenuItem } from "./MenuButton";
import { TimerButton } from "./TimerButton";
import { MAX_SESSION_MS, elapsedMs } from "../models/timeMath";
import type { Task } from "../models/task";
import type { TimeEntry } from "../models/timeEntry";
import type { Work } from "../models/work";
import type { Member } from "../models/member";
import {
  closeExpiredTimers,
  createTask,
  createWork,
  deleteTask,
  deleteWork,
  renameTask,
  renameWork,
  setTaskCritical,
  setTaskDone,
  setWorkArchived,
  toggleTimer,
} from "../data/actions";
import "./board.css";

/* The board, on real data.
 *
 * The design is the prototype's and its reasoning lives in plan.md §6; what
 * changed here is only where the rows come from. Two things the fixtures had
 * wrong, both read back out of board_screen.dart:
 *
 *   - Works sort by COMPLETENESS ASCENDING, then position — "more finished
 *     sinks lower". The fixture sorted by position alone.
 *   - `position` is a creation timestamp, written once and never updated.
 *     There is no reorder anywhere in this app.
 */

/** mm:ss / hh:mm:ss — ported from theme.dart fmtDuration. For a LIVE timer. */
function fmtDuration(s: number): string {
  const two = (n: number) => String(n).padStart(2, "0");
  const h = Math.floor(s / 3600);
  return h > 0
    ? `${two(h)}:${two(Math.floor(s / 60) % 60)}:${two(Math.floor(s) % 60)}`
    : `${two(Math.floor(s / 60))}:${two(Math.floor(s) % 60)}`;
}

/** "45s" / "17m" / "2h" / "1h 20m" — theme.dart fmtTotal. For banked time,
 *  where second-by-second precision is noise. */
function fmtTotal(s: number): string {
  if (s < 60) return `${Math.floor(s)}s`;
  const mins = Math.floor(s / 60);
  if (mins < 60) return `${mins}m`;
  const m = mins % 60;
  return m === 0 ? `${Math.floor(mins / 60)}h` : `${Math.floor(mins / 60)}h ${m}m`;
}

function useMembersById(members: Member[]) {
  return useMemo(() => new Map(members.map((m) => [m.id, m])), [members]);
}

/** The left rail: one segment per contributor, in first-touch order. */
function IdentityRail({
  entries,
  colorOf,
  nameOf,
}: {
  entries: TimeEntry[];
  colorOf: (id: string) => string;
  nameOf: (id: string) => string;
}) {
  const seen: string[] = [];
  for (const e of entries) if (!seen.includes(e.memberId)) seen.push(e.memberId);
  const liveIds = new Set(entries.filter((e) => e.endedAt === null).map((e) => e.memberId));

  if (seen.length === 0) return <span className="rail rail-empty" aria-hidden="true" />;

  return (
    <span
      className="rail"
      role="img"
      /* Colour and motion are invisible to a screen reader, and the rail is the
         board's primary answer to "who" — so it says so out loud. */
      aria-label={seen
        .map((id) => `${nameOf(id)}${liveIds.has(id) ? ", working now" : ""}`)
        .join("; ")}
    >
      {seen.map((id) => (
        <span
          key={id}
          className={"rail-seg" + (liveIds.has(id) ? " is-live" : " rail-past")}
          style={{ ["--member" as string]: colorOf(id) }}
        />
      ))}
    </span>
  );
}

function TaskRow({
  task,
  entries,
  attachmentCount,
  me,
  leaving,
  colorOf,
  nameOf,
}: {
  task: Task;
  entries: TimeEntry[];
  attachmentCount: number;
  me: string;
  leaving: boolean;
  colorOf: (id: string) => string;
  nameOf: (id: string) => string;
}) {
  const live = entries.filter((e) => e.endedAt === null);
  const mine = live.find((e) => e.memberId === me);
  const others = live.filter((e) => e.memberId !== me);

  /* clock.js's lesson, applied where it actually pays.
   *
   * A row with nothing running shows numbers that cannot change, so it
   * subscribes to a projection that is constant and never re-renders on the
   * clock at all. Only rows with a live timer tick, and they tick once a
   * second because that is what their digits show. A board of twelve tasks
   * with one timer running re-renders one row per second, not twelve. */
  const second = useClock(
    (t) => (live.length > 0 ? Math.floor(t / 1000) : 0),
    [live.length > 0],
  );
  const now = useMemo(
    () => (second > 0 ? new Date(second * 1000) : new Date()),
    [second],
  );

  /* Live entries keep counting into the team total so it never jumps backwards
   * when somebody stops — straight from the Dart's comment. Via elapsedMs, so
   * the 3h cap applies here too and a forgotten timer cannot inflate it. */
  const total = entries.reduce((acc, e) => acc + elapsedMs(e, now), 0) / 1000;
  const mineSeconds = mine ? elapsedMs(mine, now) / 1000 : 0;

  /* Near the cap, say so BEFORE it happens. A timer that vanishes with no
   * warning reads as a bug; one that warns reads as a rule. */
  const minutesLeft = mine
    ? Math.ceil((MAX_SESSION_MS - elapsedMs(mine, now)) / 60000)
    : 0;
  const nearCap = mine !== undefined && minutesLeft <= 10 && minutesLeft > 0;

  const hasSub = task.note || attachmentCount > 0 || others.length > 0 || nearCap;

  return (
    <li
      className={
        "task row-anim" + (task.isDone ? " is-done" : "") + (leaving ? " is-leaving" : "")
      }
    >
      <IdentityRail entries={entries} colorOf={colorOf} nameOf={nameOf} />

      <div className="task-hit">
        <span className="task-line">
          {/* Critical is ink, not amber — amber is Umair. Any hue here would
              name a person, so importance is carried by contrast. */}
          {task.critical && <span className="chip-critical" title="Critical">!</span>}
          <span className="task-title">{task.title}</span>
        </span>
        {hasSub && (
          <span className="task-sub">
            {others.length > 0 && (
              <span className="who-now">
                {others.map((e) => nameOf(e.memberId)).join(" & ")} working
              </span>
            )}
            {nearCap && <span className="tag-warn">stops itself in {minutesLeft}m</span>}
            {task.note && <span className="task-note">{task.note}</span>}
            {attachmentCount > 0 && (
              <span className="task-files">
                {attachmentCount} file{attachmentCount === 1 ? "" : "s"}
              </span>
            )}
          </span>
        )}
      </div>

      <span className="task-times">
        {mine ? (
          <>
            <span className="tnum time-mine is-live">{fmtDuration(mineSeconds)}</span>
            <span className="tnum time-total">{fmtTotal(total)}</span>
          </>
        ) : total > 0 ? (
          <span className="tnum time-total solo">{fmtTotal(total)}</span>
        ) : null}
      </span>

      <TimerButton
        running={mine !== undefined}
        disabled={task.isDone}
        taskTitle={task.title}
        onToggle={() => void toggleTimer(task.id)}
      />

      <div className="task-menu-slot">
        <MenuButton label={`Menu for ${task.title}`}>
          <MenuItem
            onSelect={() => {
              const t = prompt("Rename task", task.title);
              if (t && t.trim()) void renameTask(task, t);
            }}
          >
            Rename
          </MenuItem>
          <MenuItem onSelect={() => void setTaskDone(task, !task.isDone)}>
            {task.isDone ? "Mark not done" : "Mark done"}
          </MenuItem>
          <MenuItem onSelect={() => void setTaskCritical(task, !task.critical)}>
            {task.critical ? "Not critical" : "Mark critical"}
          </MenuItem>
          <MenuItem danger onSelect={() => void deleteTask(task.id)}>
            Delete
          </MenuItem>
        </MenuButton>
      </div>
    </li>
  );
}

const taskKey = (t: Task) => t.id;

function WorkSection({
  work,
  tasks,
  entriesByTask,
  attachmentsByTask,
  me,
  colorOf,
  nameOf,
}: {
  work: Work;
  tasks: Task[];
  entriesByTask: Map<string, TimeEntry[]>;
  attachmentsByTask: Map<string, number>;
  me: string;
  colorOf: (id: string) => string;
  nameOf: (id: string) => string;
}) {
  const left = tasks.filter((t) => !t.isDone).length;
  const done = tasks.length - left;

  /* A Work with nothing left arrives folded — precisely the clutter folding is
   * for. Anything unfinished arrives open. An explicit tap wins.
   * (Same default as work_folding.dart, which is per-device on purpose.) */
  const [open, setOpen] = useState(left > 0);
  /* A deleted row animates out instead of blinking away. It also has to survive
   * coming BACK, because an optimistic delete that the server refuses rolls the
   * row straight back into the list. */
  const { rendered, leaving } = useDepartures(tasks, taskKey);

  return (
    <section className="work">
      <div className="work-head">
        <button className="work-toggle" onClick={() => setOpen(!open)} aria-expanded={open}>
          <span className={"caret" + (open ? " open" : "")} aria-hidden="true">›</span>
          <h2>{work.title}</h2>
        </button>

        {/* "4 left", not "43%": one encoding of the number, and a percentage of
            seven tasks is false precision. */}
        <span className="work-count">{left > 0 ? `${left} left` : "done"}</span>

        <span
          className="work-progress"
          role="img"
          aria-label={`${done} of ${tasks.length} done`}
        >
          <span
            style={{ inlineSize: tasks.length ? `${(done / tasks.length) * 100}%` : "0%" }}
          />
        </span>

        <button
          className="icon-btn"
          aria-label={`Add task to ${work.title}`}
          onClick={() => {
            const t = prompt("New task");
            if (t && t.trim()) void createTask(work.id, t);
          }}
        >
          +
        </button>
        <MenuButton label={`Menu for ${work.title}`}>
          <MenuItem
            onSelect={() => {
              const t = prompt("Rename work", work.title);
              if (t && t.trim()) void renameWork(work, t);
            }}
          >
            Rename
          </MenuItem>
          <MenuItem onSelect={() => void setWorkArchived(work, true)}>Archive</MenuItem>
          <MenuItem
            danger
            onSelect={() => {
              if (confirm(`Delete "${work.title}" and everything in it?`)) {
                void deleteWork(work.id);
              }
            }}
          >
            Delete
          </MenuItem>
        </MenuButton>
      </div>

      {/* Always rendered; height driven by the grid fold. Conditional rendering
          would make closing instant — there would be nothing to animate. */}
      <div className={"fold" + (open ? " is-open" : "")}>
        <div>
          <ul className="tasks">
            {rendered.length === 0 && <li className="task-empty">No tasks yet</li>}
            {rendered.map((t) => (
              <TaskRow
                key={t.id}
                task={t}
                entries={entriesByTask.get(t.id) ?? []}
                attachmentCount={attachmentsByTask.get(t.id) ?? 0}
                me={me}
                leaving={leaving.has(t.id)}
                colorOf={colorOf}
                nameOf={nameOf}
              />
            ))}
          </ul>
        </div>
      </div>
    </section>
  );
}

export function Board() {
  const s = useStore();
  const byId = useMembersById(s.members);

  /* Unknown member renders as ink, never as a colour. The Dart defaulted to
   * '#00A896' — which is Shayaan, so a missing member silently became him. */
  const colorOf = (id: string) => byId.get(id)?.color || "var(--ink-3)";
  const nameOf = (id: string) => byId.get(id)?.name ?? "someone";

  const entriesByTask = useMemo(() => {
    const m = new Map<string, TimeEntry[]>();
    for (const e of s.entries) {
      const list = m.get(e.taskId);
      if (list) list.push(e);
      else m.set(e.taskId, [e]);
    }
    return m;
  }, [s.entries]);

  const attachmentsByTask = useMemo(() => {
    const m = new Map<string, number>();
    for (const a of s.attachments) m.set(a.taskId, (m.get(a.taskId) ?? 0) + 1);
    return m;
  }, [s.attachments]);

  const tasksByWork = useMemo(() => {
    const m = new Map<string, Task[]>();
    for (const t of s.tasks) {
      if (t.isArchived) continue;
      const list = m.get(t.workId);
      if (list) list.push(t);
      else m.set(t.workId, [t]);
    }
    for (const list of m.values()) list.sort((a, b) => a.position - b.position);
    return m;
  }, [s.tasks]);

  /* board_screen.dart:69-88 — works sort by completeness ASCENDING, tie-broken
   * by position. "More finished sinks lower", so what still needs doing is at
   * the top. An empty work counts as 0 complete, not 100%. */
  const works = useMemo(() => {
    const completeness = (w: Work) => {
      const list = tasksByWork.get(w.id) ?? [];
      if (list.length === 0) return 0;
      return list.filter((t) => t.isDone).length / list.length;
    };
    return s.works
      .filter((w) => !w.archived)
      .slice()
      .sort((a, b) => {
        const c = completeness(a) - completeness(b);
        return c !== 0 ? c : a.position - b.position;
      });
  }, [s.works, tasksByWork]);

  /* The client half of the three-hour cap. The server hook is what makes it
   * true when nobody is looking; this is what makes it true the moment somebody
   * opens the page, and both write the same value. Checked once a minute — the
   * arithmetic is already capped, so the only thing this changes is when the
   * row stops saying "live". */
  useEffect(() => {
    void closeExpiredTimers();
    const id = setInterval(() => void closeExpiredTimers(), 60_000);
    return () => clearInterval(id);
  }, []);

  const me = s.me;
  if (!me) return null;

  return (
    <div className="board">
      <header className="board-head">
        <div>
          <p className="label">Board</p>
          <h1>What everyone is on</h1>
        </div>
        <span className="whoami" style={{ ["--member" as string]: me.color || "var(--ink-3)" }}>
          <span className="member-dot" />
          {me.name}
        </span>
      </header>

      {works.length === 0 && (
        <p className="board-empty">
          Nothing here yet. Add a Work to start tracking something.
        </p>
      )}

      {works.map((w) => (
        <WorkSection
          key={w.id}
          work={w}
          tasks={tasksByWork.get(w.id) ?? []}
          entriesByTask={entriesByTask}
          attachmentsByTask={attachmentsByTask}
          me={me.id}
          colorOf={colorOf}
          nameOf={nameOf}
        />
      ))}

      <button
        className="add-work"
        onClick={() => {
          const t = prompt("New work");
          if (t && t.trim()) void createWork(t);
        }}
      >
        + Add a Work
      </button>
    </div>
  );
}
