import { pb } from "./pb";
import { set, resetStore } from "./store";
import { startSync, stopSync } from "./sync";
import { toMember, type Member } from "../models/member";

/* Sign-in, ported from pocketbase_repo.dart:140-149 and pick_name_screen.dart.
 *
 * The shape is unusual and deliberate: there is ONE shared password and three
 * named members, so signing in is "pick a face, then type the password". The
 * email is never shown to anyone — it is derived from the name and exists only
 * because PocketBase needs an identity field.
 *
 * The honest limit, worth keeping in view because the file explorer depends on
 * it (plan.md §11.4): anyone who knows the password can sign in as any of the
 * three. "Uploaded by Umair" means "whoever was signed in as Umair". */

const emailFor = (name: string): string =>
  `${name.trim().toLowerCase()}@teamstream.local`;

/** The login picker's list. Readable BEFORE signing in, because `members` has
 *  `listRule: ""` — that is what lets the picker render at all. */
export async function fetchMembers(): Promise<Member[]> {
  const rows = await pb.collection("members").getFullList({ sort: "name" });
  return rows.map(toMember);
}

export async function signIn(name: string, password: string): Promise<string | null> {
  try {
    const res = await pb
      .collection("members")
      .authWithPassword(emailFor(name), password);
    set({ signedIn: true, me: toMember(res.record), booted: false });
    await startSync();
    return null;
  } catch {
    /* One sentence, exactly as the Dart says it. Splitting "wrong password"
     * from "server unreachable" would be more informative and also a small
     * oracle for anyone guessing — and with three people sharing one password,
     * the distinction changes nothing about what you do next: try again. */
    return "Wrong password, or the server is unreachable.";
  }
}

export async function signOut(): Promise<void> {
  await stopSync();
  pb.authStore.clear();
  resetStore();
}

/** Called once at startup. A stored token that is still valid signs straight
 *  back in; anything else lands on the picker. */
export async function restoreSession(): Promise<void> {
  if (!pb.authStore.isValid || !pb.authStore.record) {
    set({ signedIn: false });
    return;
  }
  set({ signedIn: true, me: toMember(pb.authStore.record) });
  await startSync();
}

/* The SDK refreshes the token on its own, but it cannot invent a new one once
 * the stored one has genuinely expired. When that happens mid-session every
 * write starts failing with a 401 and the UI would just accumulate errors, so
 * drop to the login screen instead of pretending. */
pb.authStore.onChange(() => {
  if (!pb.authStore.isValid) {
    void stopSync().then(resetStore);
  }
});
