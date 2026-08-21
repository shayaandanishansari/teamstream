import PocketBase, { LocalAuthStore } from "pocketbase";

/* The one PocketBase client.
 *
 * BASE URL: relative, always. In production PocketBase serves the React build
 * out of pb_public/ and its own API from /api on the same origin; in dev the
 * Vite proxy forwards /api to :8090. So the browser's own origin is correct in
 * both, and `config.dart`'s three-way resolution (a --dart-define override, a
 * same-origin default on web, a hardcoded host on native) collapses to nothing.
 * That also deletes the trap run.bat documents today, where the dev server and
 * PocketBase are on different ports and every API call comes back as index.html.
 *
 * AUTH STORE KEY: deliberately NOT `pb_auth`, which is what the Dart app uses.
 * Sharing the key would let a phone stay signed in across the cutover, which is
 * worth roughly one password entry for three people — and the Dart and JS SDKs
 * serialise the stored blob differently enough (`model` vs `record`) that a
 * mis-parse would leave the app believing it is authenticated as a member
 * object with no id. A confusing broken state, to save one login. Separate key.
 */
export const pb = new PocketBase("/", new LocalAuthStore("pb_auth_web"));

/* PocketBase's JS SDK auto-cancels a pending request when an identical one is
 * made — helpful in a search box, actively wrong for our loads, which fire
 * several same-shaped getFullLists at boot. Off globally; where we want
 * cancellation we do it explicitly. */
pb.autoCancellation(false);

export const currentMemberId = (): string | null => pb.authStore.record?.id ?? null;
export const currentMemberName = (): string => (pb.authStore.record?.name as string) ?? "";

/** Attribution for every mutating call.
 *
 * `history.pb.js` reads these off the request and stores them on the log row;
 * PocketBase lowercases and underscores header names, so `X-Actor-Id` arrives
 * as `x_actor_id`. Sent on writes only — the Dart never puts them on reads and
 * neither do we, because a read is not an event. */
export const actorHeaders = (): Record<string, string> => ({
  "X-Actor-Id": currentMemberId() ?? "",
  "X-Actor-Name": currentMemberName(),
});
