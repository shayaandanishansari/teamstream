import { useEffect, useState } from "react";
import { fetchMembers, signIn } from "../data/auth";
import type { Member } from "../models/member";
import "./login.css";

/* Port of pick_name_screen.dart.
 *
 * Two steps, because there is one shared password and three people: pick a
 * face, then type it. The member list renders BEFORE anyone is signed in,
 * which works because `members` has `listRule: ""` — that is the whole reason
 * that rule is public, and the reason the migration comments say so.
 */
export function LoginScreen() {
  const [members, setMembers] = useState<Member[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [picked, setPicked] = useState<Member | null>(null);
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    fetchMembers()
      .then(setMembers)
      .catch(() => setLoadError("Could not reach the server."));
  }, []);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!picked || busy) return;
    setBusy(true);
    setError(null);
    const message = await signIn(picked.name, password);
    setBusy(false);
    if (message) {
      setError(message);
      setPassword("");
    }
  }

  return (
    <main className="login">
      <header>
        <p className="label">TeamStream</p>
        <h1>{picked ? `Hello, ${picked.name}` : "Who are you?"}</h1>
      </header>

      {picked === null ? (
        <>
          {loadError && <p className="login-error">{loadError}</p>}
          {members === null && !loadError && <p className="login-hint">Loading…</p>}
          <ul className="who">
            {members?.map((m) => (
              <li key={m.id}>
                <button
                  className="who-btn"
                  style={{ ["--member" as string]: m.color || "var(--ink-3)" }}
                  onClick={() => setPicked(m)}
                >
                  <span className="member-dot" />
                  {m.name}
                </button>
              </li>
            ))}
          </ul>
        </>
      ) : (
        <form onSubmit={submit} className="pw">
          <label htmlFor="pw" className="label">
            Password
          </label>
          <input
            id="pw"
            type="password"
            autoFocus
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            disabled={busy}
          />
          {/* One sentence, as the Dart says it: splitting "wrong password" from
              "server unreachable" is a small oracle for anyone guessing, and
              with a shared password it changes nothing about what you do next. */}
          {error && <p className="login-error" role="alert">{error}</p>}
          <div className="pw-actions">
            <button
              type="button"
              className="ghost"
              onClick={() => { setPicked(null); setError(null); setPassword(""); }}
              disabled={busy}
            >
              Back
            </button>
            <button type="submit" disabled={busy || password.length === 0}>
              {busy ? "Signing in…" : "Sign in"}
            </button>
          </div>
        </form>
      )}
    </main>
  );
}
