import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

/* Dev is same-origin, exactly as production is.
 *
 * In production PocketBase serves this build out of pb_public/ at `/` and its
 * own API at `/api`, and cloudflared routes `/files/*` to the FastAPI service —
 * all one origin. The proxy below reproduces that on the dev server, so every
 * URL in the client is relative in both and there is no environment switch to
 * get wrong.
 *
 * This is what deletes the trap run.bat documents today: the Flutter dev server
 * and PocketBase sit on different ports, so `config.dart`'s same-origin default
 * aims the API at the dev server and every call comes back as index.html —
 * hence the mandatory `--dart-define=PB_URL`. With a proxy there is nothing to
 * define.
 *
 * It also matters for the file service specifically. `ts_files` is a cookie
 * scoped to `Path=/files`, and cookies are origin-scoped: without the proxy the
 * cookie would be set on :8091 and never sent by an `<img>` on :5173. That is a
 * failure that would only ever show up in production.
 */
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    /* Fail rather than drift. Vite's default is to walk to the next free port,
     * which is friendly for a static site and wrong here: `ts_files` is a
     * cookie scoped to this origin, so a dev server that quietly moves to :5174
     * is a different origin with a different session, and the resulting "why am
     * I logged out" is a puzzle rather than a message. Explicit ask, hard
     * failure. */
    strictPort: true,
    proxy: {
      /* changeOrigin: false keeps the browser's Host as the dev origin, so a
       * Set-Cookie with no Domain attribute scopes to :5173 — the same shape it
       * has in production. */
      "/api": { target: "http://127.0.0.1:8090", changeOrigin: false },
      "/files": { target: "http://127.0.0.1:8091", changeOrigin: false },
      /* PocketBase's realtime is SSE over /api/realtime, which the rule above
       * already covers. It must not be buffered or compressed on the way
       * through; Vite streams proxied responses, which is why this works. */
    },
  },
});
