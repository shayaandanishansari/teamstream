import { useEffect, useRef, useState } from "react";

/* The hot value, kept out of the store — video_editor/app/ui/clock.js, ported.
 *
 * Its rule: "The playhead is not in the store. `timeupdate` fires four times a
 * second and would otherwise re-render the whole editor for a number that three
 * small things care about." TeamStream has the identical problem one order of
 * magnitude slower: a running timer ticks once a second, and the board can hold
 * a dozen rows of which one is live.
 *
 * The fix is the same. `now` lives here, not in the store, and components
 * subscribe to a DERIVED value — so a row showing "17m" re-renders once a
 * minute rather than sixty times, and rows with no live timer never re-render
 * at all.
 */

let now = Date.now();
const subs = new Set<(t: number) => void>();
let timer: ReturnType<typeof setInterval> | null = null;

/* One interval for the whole app, started when the first subscriber arrives and
 * stopped when the last leaves. Aligned to the next whole second so the digits
 * across the board all flip on the same frame rather than drifting apart by
 * whatever fraction each component happened to mount at. */
function ensureRunning(): void {
  if (timer !== null) return;
  const tick = () => {
    now = Date.now();
    for (const fn of [...subs]) fn(now);
  };
  const delay = 1000 - (Date.now() % 1000);
  setTimeout(() => {
    if (subs.size === 0) return;
    tick();
    timer = setInterval(tick, 1000);
  }, delay);
}

function stopIfIdle(): void {
  if (subs.size === 0 && timer !== null) {
    clearInterval(timer);
    timer = null;
  }
}

export const timeNow = (): number => now;

/**
 * Subscribe to a projection of the clock.
 *
 * @param select  t -> some value. Keep it cheap; it runs on every tick.
 * @param deps    re-subscribe when these change (whatever `select` closes over)
 *
 * The component re-renders only when the SELECTED value changes, which is the
 * whole point: pass `t => Math.floor(elapsed(t) / 60000)` and you re-render once
 * a minute no matter how often the clock ticks.
 */
export function useClock<T>(select: (t: number) => T, deps: unknown[] = []): T {
  const [value, setValue] = useState<T>(() => select(now));
  const held = useRef<T>(value);

  useEffect(() => {
    const fn = (t: number) => {
      const next = select(t);
      if (!Object.is(next, held.current)) {
        held.current = next;
        setValue(next);
      }
    };
    // deps changed under us: resync immediately rather than showing a stale
    // projection until the next tick.
    fn(now);
    subs.add(fn);
    ensureRunning();
    return () => {
      subs.delete(fn);
      stopIfIdle();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);

  return value;
}

/** For the handful of places that genuinely want a Date every second. */
export const useNow = (): Date => new Date(useClock((t) => Math.floor(t / 1000) * 1000));
