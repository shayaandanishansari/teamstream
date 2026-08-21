/* Clear anything the Flutter build left behind on a phone.
 *
 * WHAT THE RISK ACTUALLY IS, having read the file rather than assumed.
 * `backend/pb_public/flutter_service_worker.js` is Flutter's 31-line
 * SELF-DESTRUCTING worker — it calls `registration.unregister()` on activate
 * and reloads its clients. So a phone that has opened the app since the last
 * rebuild has already had its worker removed. The landmine is narrower than it
 * looks. It is not zero:
 *
 *   - a phone that has not opened the app since BEFORE that build may still
 *     carry an older CACHING worker scoped to `/`, which would serve the stale
 *     Flutter shell and intercept `/files/*` fetches;
 *   - an installed PWA can serve its start_url from the HTTP cache with no
 *     worker involved at all.
 *
 * Both are fixed by clearing everything once, on first load of the new app.
 *
 * THIS IS SAFE TO DO UNCONDITIONALLY because the new app deliberately ships NO
 * service worker. Offline is not a requirement for a tracker whose entire value
 * is live shared state — an offline board showing yesterday's timers is worse
 * than a board that says it cannot reach the server. So there is nothing here
 * that could fight something we want to keep.
 *
 * See also `web/public/flutter_service_worker.js`: we keep SERVING that script
 * after the cutover rather than letting the URL 404. A registered worker updates
 * by re-fetching its own script; browsers may unregister it on a 404, but the
 * behaviour is not uniform across engines and it is not worth betting three
 * phones on. Serving a script that tears itself down is deterministic. A 404 is
 * a hope.
 */

const FLAG = "ts.purged.v1";

export async function purgeLegacy(): Promise<void> {
  if (localStorage.getItem(FLAG) === "1") return;

  let removed = 0;

  try {
    if ("serviceWorker" in navigator) {
      const registrations = await navigator.serviceWorker.getRegistrations();
      await Promise.all(registrations.map((r) => r.unregister()));
      removed += registrations.length;
    }
  } catch {
    /* A browser that refuses to enumerate workers is a browser with none we
     * can reach; nothing to do but carry on and render. */
  }

  try {
    if ("caches" in globalThis) {
      const keys = await caches.keys();
      await Promise.all(keys.map((k) => caches.delete(k)));
      removed += keys.length;
    }
  } catch {
    /* ditto */
  }

  localStorage.setItem(FLAG, "1");

  /* Only reload when something was ACTUALLY removed. An unconditional reload
   * would double every first load forever; a conditional one runs at most once
   * per device, and only where the old app really was installed. */
  if (removed > 0) location.reload();
}
