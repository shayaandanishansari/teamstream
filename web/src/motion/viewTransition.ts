import { flushSync } from "react-dom";

/* Page swaps, via the browser's native View Transitions API.
 *
 * Why not React's <ViewTransition>: it exists only in React's experimental
 * builds, and this project is on stable 19.2.8. The native API does the same
 * job here and costs no dependency — which matters, since a small bundle is
 * half the reason we left Flutter.
 *
 * The mechanism: the browser screenshots the old frame, we swap the DOM
 * synchronously inside the callback, it screenshots the new one and crossfades
 * between them. `flushSync` is not optional — React would otherwise batch the
 * state update to after the callback returns, the browser would screenshot a
 * DOM that had not changed yet, and the transition would animate nothing.
 */

/** Feature-detected each call rather than cached: cheap, and it keeps this
 *  honest on browsers that gain the API mid-session behind a flag. */
type WithVT = Document & {
  startViewTransition?: (cb: () => void) => { finished: Promise<void> };
};

const reduced = () =>
  typeof matchMedia === "function" &&
  matchMedia("(prefers-reduced-motion: reduce)").matches;

/**
 * Run `update` inside a view transition when the browser can, plainly when it
 * cannot.
 *
 * Both fallbacks matter and neither is a degradation worth apologising for:
 * Firefox has no same-document View Transitions yet, and somebody who has asked
 * their OS for less motion has asked for exactly this. The state change still
 * happens identically in every case — only the crossfade is conditional. That
 * is the whole reason to do page swaps this way instead of with mount/unmount
 * animation, which breaks outright when it is switched off.
 */
export const supportsViewTransitions = (): boolean =>
  typeof (document as WithVT).startViewTransition === "function";

/**
 * Stamp `no-vt` on <html> when the API is missing, so CSS can supply a fallback
 * animation instead of the swap simply being instant. Called once at startup.
 *
 * A class on the root rather than a media/supports query because there is no
 * `@supports` test for a JS API, and scoping the fallback this way guarantees it
 * can never run alongside a real view transition and double up.
 */
export function markViewTransitionSupport(): void {
  if (!supportsViewTransitions()) {
    document.documentElement.classList.add("no-vt");
  }
}

/** For the prototype's diagnostic readout — why a swap did or did not animate. */
export function motionStatus(): string {
  if (reduced()) return "reduced-motion is on — animation off by request";
  return supportsViewTransitions() ? "view transitions" : "fallback (no API)";
}

export function withViewTransition(update: () => void): void {
  const doc = document as WithVT;
  if (typeof doc.startViewTransition !== "function" || reduced()) {
    update();
    return;
  }
  doc.startViewTransition(() => flushSync(update));
}
