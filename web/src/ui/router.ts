import { useSyncExternalStore } from "react";
import { withViewTransition } from "../motion/viewTransition";

/* A router, in fifty lines, because five routes do not need fifteen kilobytes.
 *
 * The one thing it must do that a library would fight: run every navigation
 * inside `withViewTransition`, so the page-swap animation already built in
 * motion.css applies to real navigation rather than only to the prototype's
 * toggle. React Router does not drive `document.startViewTransition` on stable
 * React, so this would be a wrapper around it anyway.
 *
 * `/drive` and not `/files`: the cloudflared ingress rule sends everything
 * matching `^/files(/|$)` to the FastAPI service, so a browser navigating to
 * `/files` would get an API 404 instead of the app. An API prefix and a client
 * route cannot share a namespace.
 */

export const ROUTES = ["/", "/dashboard", "/drive", "/calendar"] as const;
export type Route = (typeof ROUTES)[number];

const isRoute = (p: string): p is Route => (ROUTES as readonly string[]).includes(p);

/** Unknown paths render the board rather than a 404 page — with four routes and
 *  three users, a wrong URL is a typo, not a destination. */
export const normalise = (p: string): Route => (isRoute(p) ? p : "/");

const listeners = new Set<() => void>();
const notify = () => { for (const fn of [...listeners]) fn(); };

function subscribe(fn: () => void): () => void {
  listeners.add(fn);
  return () => { listeners.delete(fn); };
}

/* The back button fires popstate and never goes through `navigate`, so without
 * this a browser-driven navigation would swap instantly while a clicked one
 * animated — the same movement rendered two different ways. One listener, at
 * module scope, so it cannot be registered twice. */
addEventListener("popstate", () => {
  withViewTransition(() => { notify(); });
});

/* Read from location on every call rather than caching: useSyncExternalStore
 * needs a stable snapshot, and a string literal from a fixed set is stable by
 * value, so this is safe and cannot go out of step with the address bar. */
const snapshot = (): Route => normalise(location.pathname);

export const useRoute = (): Route =>
  useSyncExternalStore(subscribe, snapshot, () => "/" as Route);

export function navigate(to: Route, replace = false): void {
  if (snapshot() === to) return;
  withViewTransition(() => {
    history[replace ? "replaceState" : "pushState"]({}, "", to);
    notify();
  });
}
