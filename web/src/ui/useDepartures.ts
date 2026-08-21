import { useEffect, useRef, useState } from "react";
import { durationMs } from "../motion/duration";

/* Keep a removed item on screen just long enough to animate it away.
 *
 * React unmounts immediately, so a row deleted from the store vanishes on the
 * next frame with nothing to animate. motion.css handles enter-and-exit for
 * anything toggled by `display` or `popover` (@starting-style plus
 * transition-behavior: allow-discrete), but a list item is a genuine
 * mount/unmount and that trick cannot reach it.
 *
 * So: diff the incoming list, hold anything that disappeared for one animation,
 * and mark it `.is-leaving` while it goes. This is the generic version of what
 * the board prototype did inline, and the drive needs the same thing.
 *
 * The delay is READ FROM --dur-fast rather than typed here, so retuning the
 * token cannot leave rows vanishing mid-fade or lingering after they have
 * finished fading.
 */
export function useDepartures<T>(
  items: T[],
  keyOf: (item: T) => string,
): { rendered: T[]; leaving: ReadonlySet<string> } {
  const [departing, setDeparting] = useState<Map<string, T>>(new Map());
  const previous = useRef<Map<string, T>>(new Map());
  const timers = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());

  useEffect(() => {
    const current = new Map(items.map((i) => [keyOf(i), i]));

    for (const [key, item] of previous.current) {
      if (current.has(key)) continue;
      setDeparting((d) => new Map(d).set(key, item));
      const t = setTimeout(() => {
        setDeparting((d) => {
          const next = new Map(d);
          next.delete(key);
          return next;
        });
        timers.current.delete(key);
      }, durationMs("--dur-fast", 150));
      timers.current.set(key, t);
    }

    /* An item that comes BACK while it is still leaving — an optimistic delete
     * that failed and rolled back — must stop leaving at once, or it would
     * reappear already faded and then pop. */
    for (const key of current.keys()) {
      const t = timers.current.get(key);
      if (t !== undefined) {
        clearTimeout(t);
        timers.current.delete(key);
        setDeparting((d) => {
          if (!d.has(key)) return d;
          const next = new Map(d);
          next.delete(key);
          return next;
        });
      }
    }

    previous.current = current;
  }, [items, keyOf]);

  useEffect(() => {
    const running = timers.current;
    return () => {
      for (const t of running.values()) clearTimeout(t);
      running.clear();
    };
  }, []);

  const live = new Set(items.map(keyOf));
  const rendered = [...items];
  for (const [key, item] of departing) if (!live.has(key)) rendered.push(item);

  return { rendered, leaving: new Set(departing.keys()) };
}
