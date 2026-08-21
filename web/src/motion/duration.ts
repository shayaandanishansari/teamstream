/* Read a duration token out of the CSS, so JS timing cannot drift from it.
 *
 * Any exit animation needs JS to hold the element alive for exactly as long as
 * the CSS spends animating it. Hardcoding `150` next to a `--dur-fast: 150ms`
 * works right up until someone retunes the token, at which point rows start
 * vanishing mid-fade with nothing to explain why. Reading the value means there
 * is one number, in the design system, where it belongs.
 */

const cache = new Map<string, number>();

export function durationMs(token: string, fallback: number): number {
  const hit = cache.get(token);
  if (hit !== undefined) return hit;

  const raw = getComputedStyle(document.documentElement)
    .getPropertyValue(token)
    .trim();

  const parsed = raw.endsWith("ms")
    ? parseFloat(raw)
    : raw.endsWith("s")
      ? parseFloat(raw) * 1000
      : NaN;

  const value = Number.isFinite(parsed) ? parsed : fallback;
  cache.set(token, value);
  return value;
}
