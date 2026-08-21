import { afterEach, beforeEach, describe, expect, it } from "vitest";
import timezoneMock from "timezone-mock";
import {
  MAX_SESSION_MS,
  effectiveEnd,
  elapsedMs,
  hasExpired,
  overlapWithinMs,
  startOfDay,
  startOfMonth,
  startOfWeek,
  nextDay,
  type TimeEntry,
} from "./timeMath";

const HOUR = 3_600_000;

const entry = (startedAt: Date, endedAt: Date | null = null): TimeEntry => ({
  id: "e1",
  taskId: "t1",
  memberId: "m1",
  startedAt,
  endedAt,
});

describe("day boundaries", () => {
  it("truncates to local midnight", () => {
    const d = startOfDay(new Date(2026, 7, 20, 14, 33, 12, 500));
    expect([d.getHours(), d.getMinutes(), d.getSeconds(), d.getMilliseconds()])
      .toEqual([0, 0, 0, 0]);
    expect(d.getDate()).toBe(20);
  });

  it("rolls over a month end", () => {
    expect(nextDay(new Date(2026, 0, 31)).getMonth()).toBe(1); // Jan 31 -> Feb 1
    expect(nextDay(new Date(2026, 0, 31)).getDate()).toBe(1);
  });

  it("handles a leap day", () => {
    const d = nextDay(new Date(2024, 1, 28)); // 2024 is a leap year
    expect(d.getMonth()).toBe(1);
    expect(d.getDate()).toBe(29);
  });
});

describe("startOfWeek is Monday-anchored", () => {
  /* This is the one place the port could go wrong silently. Dart numbers
   * Mon..Sun as 1..7; JS numbers Sun..Sat as 0..6. A direct transliteration
   * anchors the week to Sunday and shifts every weekly total by a day —
   * a bug that looks like "the dashboard is a bit off" rather than a crash. */
  it("returns Monday for every day of a known week", () => {
    // Mon 2026-08-17 through Sun 2026-08-23.
    for (let i = 0; i < 7; i++) {
      const day = new Date(2026, 7, 17 + i, 13, 0, 0);
      const monday = startOfWeek(day);
      expect(monday.getDay()).toBe(1);        // 1 === Monday in JS
      expect(monday.getDate()).toBe(17);
      expect(monday.getHours()).toBe(0);
    }
  });

  it("puts Sunday at the END of its week, not the start", () => {
    const sunday = new Date(2026, 7, 23, 23, 59);
    expect(sunday.getDay()).toBe(0);
    expect(startOfWeek(sunday).getDate()).toBe(17); // the Monday BEFORE it
  });

  it("crosses a month boundary backwards", () => {
    const wed = new Date(2026, 8, 2); // Wed 2 Sep 2026
    const monday = startOfWeek(wed);
    expect(monday.getMonth()).toBe(7); // back into August
    expect(monday.getDate()).toBe(31);
  });
});

describe("startOfMonth", () => {
  it("truncates to the first at midnight", () => {
    const d = startOfMonth(new Date(2026, 7, 20, 9, 15));
    expect(d.getDate()).toBe(1);
    expect(d.getHours()).toBe(0);
  });
});

describe("overlapWithin slices rather than buckets", () => {
  const now = new Date(2026, 7, 20, 12, 0);

  it("counts a fully-contained entry whole", () => {
    const from = startOfDay(now);
    const to = nextDay(now);
    const e = entry(new Date(2026, 7, 20, 9, 0), new Date(2026, 7, 20, 11, 0));
    expect(overlapWithinMs(e, from, to, now)).toBe(2 * HOUR);
  });

  it("clips an entry that starts before the window", () => {
    const from = startOfDay(now);
    const to = nextDay(now);
    const e = entry(new Date(2026, 7, 19, 22, 0), new Date(2026, 7, 20, 2, 0));
    expect(overlapWithinMs(e, from, to, now)).toBe(2 * HOUR); // only the 00:00-02:00 half
  });

  it("splits an overnight timer across both days", () => {
    // The reason the function exists: 22:00 -> 02:00 belongs to two days.
    const e = entry(new Date(2026, 7, 19, 22, 0), new Date(2026, 7, 20, 2, 0));
    const d19 = overlapWithinMs(e, startOfDay(new Date(2026, 7, 19)), startOfDay(new Date(2026, 7, 20)), now);
    const d20 = overlapWithinMs(e, startOfDay(new Date(2026, 7, 20)), startOfDay(new Date(2026, 7, 21)), now);
    expect(d19).toBe(2 * HOUR);
    expect(d20).toBe(2 * HOUR);
    expect(d19 + d20).toBe(4 * HOUR); // and nothing is double-counted
  });

  it("treats a live entry as running up to now", () => {
    const e = entry(new Date(2026, 7, 20, 10, 0), null);
    const from = startOfDay(now);
    const to = nextDay(now);
    expect(overlapWithinMs(e, from, to, now)).toBe(2 * HOUR);
  });

  it("returns zero for an entry outside the window instead of a negative", () => {
    const e = entry(new Date(2026, 7, 18, 9, 0), new Date(2026, 7, 18, 10, 0));
    const from = startOfDay(now);
    const to = nextDay(now);
    expect(overlapWithinMs(e, from, to, now)).toBe(0);
  });

  it("is zero-width for an instantaneous entry", () => {
    const t = new Date(2026, 7, 20, 10, 0);
    expect(overlapWithinMs(entry(t, t), startOfDay(now), nextDay(now), now)).toBe(0);
  });
});

/* The DST case the Dart comment is about — and it really runs.
 *
 * It could not before. Node on Windows ignores the TZ environment variable
 * outright, so `TZ=Europe/London vitest` runs in the machine's own zone
 * regardless; this box is Asia/Karachi, which has had no DST since 2009, so
 * there was no transition to test against and both assertions skipped. A test
 * that only comes alive on someone else's machine protects nobody here, and
 * "unproven" had been quietly reading as "passing".
 *
 * `timezone-mock` patches the global Date to emulate a zone that does have
 * transitions, so the assertions run everywhere — including on the machine
 * where the mistake they guard against would actually be typed.
 *
 * What they guard: `nextDay` is `new Date(y, m, d + 1)`, and the tempting
 * "simplification" is `new Date(d.getTime() + 86400000)`. In a fixed-offset
 * zone those two are indistinguishable, which is exactly why this needs a
 * zone that moves. On 8 March 2026 US/Pacific springs forward, so the day is
 * 23 hours long: the constructor lands on midnight, the arithmetic lands on
 * 01:00 the next day and drags every day/week window an hour out of place.
 */
describe("DST", () => {
  // Spring forward: 2026-03-08 in US/Pacific is a 23-hour day.
  const SPRING = { y: 2026, m: 2, d: 8, hours: 23 };
  // Fall back: 2026-11-01 is a 25-hour day. Both directions, because an
  // off-by-one-hour bug can hide in one of them.
  const FALL = { y: 2026, m: 10, d: 1, hours: 25 };

  beforeEach(() => { timezoneMock.register("US/Pacific"); });
  afterEach(() => { timezoneMock.unregister(); });

  it("is really running in a zone that has transitions", () => {
    const winter = new Date(2026, 0, 15, 12).getTimezoneOffset();
    const summer = new Date(2026, 6, 15, 12).getTimezoneOffset();
    expect(winter).not.toBe(summer);
  });

  for (const { y, m, d, hours } of [SPRING, FALL]) {
    const label = hours === 23 ? "spring forward" : "fall back";

    it(`keeps a day window anchored to midnight across ${label}`, () => {
      const day = new Date(y, m, d, 12);
      const from = startOfDay(day);
      const to = nextDay(day);

      // Midnight stays midnight on both ends. This is the assertion that fails
      // the moment someone swaps the constructor for +86400000.
      expect(from.getHours()).toBe(0);
      expect(to.getHours()).toBe(0);
      expect(to.getDate()).toBe(d + 1);

      // And the day is genuinely not 24 hours long, which is the whole point.
      expect((to.getTime() - from.getTime()) / HOUR).toBe(hours);
    });

    it(`credits a timer spanning ${label} its real elapsed time`, () => {
      const day = new Date(y, m, d, 12);
      const from = startOfDay(day);
      const to = nextDay(day);
      // Wall clock 00:00 -> 00:00, but the person was at the desk for 23 or 25
      // actual hours and should be paid for what happened, not for what the
      // calendar says a day is.
      expect(overlapWithinMs(entry(from, to), from, to, to) / HOUR).toBe(hours);
    });
  }

  it("keeps a week anchored to Monday midnight across a transition", () => {
    // The Sunday of the spring-forward weekend: startOfWeek must still reach
    // back to Monday 00:00, not Monday 01:00.
    const sunday = new Date(2026, 2, 8, 12);
    const monday = startOfWeek(sunday);
    expect(monday.getDay()).toBe(1);
    expect(monday.getHours()).toBe(0);
    expect(monday.getDate()).toBe(2);
  });
});

describe("the 3-hour cap", () => {
  const start = new Date(2026, 7, 20, 9, 0);
  const live = entry(start, null);

  it("is three hours", () => {
    expect(MAX_SESSION_MS).toBe(3 * HOUR);
  });

  it("counts a live entry normally before the cap", () => {
    const now = new Date(2026, 7, 20, 11, 0); // 2h in
    expect(elapsedMs(live, now)).toBe(2 * HOUR);
    expect(hasExpired(live, now)).toBe(false);
  });

  it("stops counting at exactly three hours", () => {
    const now = new Date(2026, 7, 20, 12, 0);
    expect(elapsedMs(live, now)).toBe(3 * HOUR);
    expect(hasExpired(live, now)).toBe(true);
  });

  it("does not keep counting after the cap, however long it is left", () => {
    // The case the cap exists for: a timer left running over a weekend.
    const monday = new Date(2026, 7, 24, 9, 0);
    expect(elapsedMs(live, monday)).toBe(3 * HOUR);
    expect(effectiveEnd(live, monday).getTime()).toBe(start.getTime() + 3 * HOUR);
  });

  it("leaves a normally-stopped short entry alone", () => {
    const stopped = entry(start, new Date(2026, 7, 20, 9, 45));
    const now = new Date(2026, 7, 20, 18, 0);
    expect(elapsedMs(stopped, now)).toBe(45 * 60_000);
    expect(hasExpired(stopped, now)).toBe(false);
  });

  it("does NOT cap an entry a person actually stopped", () => {
    /* The distinction the whole feature turns on. Somebody who genuinely worked
     * four hours and pressed stop keeps their four hours; capping a stopped
     * entry would silently delete real logged work. The cap closes timers that
     * were left running — it is not a ceiling on how long a session may be. */
    const long = entry(start, new Date(2026, 7, 20, 13, 0)); // 4h, stopped
    expect(elapsedMs(long, new Date(2026, 7, 20, 21, 0))).toBe(4 * HOUR);
    expect(hasExpired(long, new Date(2026, 7, 20, 21, 0))).toBe(false);
  });

  it("never reports a live entry as expired before its time", () => {
    const oneMsShort = new Date(start.getTime() + MAX_SESSION_MS - 1);
    expect(hasExpired(live, oneMsShort)).toBe(false);
  });

  it("keeps day totals honest for a runaway timer", () => {
    /* The integration that matters: a timer started at 09:00 and never stopped
     * must post 3h to its day, not the whole rest of the day. Without the cap
     * inside overlapWithinMs the dashboard and the board would disagree about
     * the same task. */
    const now = new Date(2026, 7, 20, 23, 0); // 14 hours later
    const from = startOfDay(now);
    const to = nextDay(now);
    expect(overlapWithinMs(live, from, to, now)).toBe(3 * HOUR);
  });

  it("gives a runaway timer nothing on the following day", () => {
    const now = new Date(2026, 7, 21, 10, 0);
    const from = startOfDay(now);
    const to = nextDay(now);
    // It ended at 12:00 the previous day, so today gets zero.
    expect(overlapWithinMs(live, from, to, now)).toBe(0);
  });
});
