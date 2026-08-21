import { useEffect } from "react";
import { useStore, dismissWriteError } from "./data/store";
import { restoreSession, signOut } from "./data/auth";
import { markViewTransitionSupport } from "./motion/viewTransition";
import { navigate, useRoute, type Route } from "./ui/router";
import { LoginScreen } from "./ui/LoginScreen";
import { Board } from "./ui/Board";
import { Dashboard } from "./ui/Dashboard";
import { Drive } from "./ui/Drive";
import "./ui/shell.css";

/* The app shell — port of app_shell.dart.
 *
 * Its three jobs are the Dart's three: decide whether we are signed in, put a
 * nav around the screens, and surface write failures. The Dart shows the last
 * one as a snackbar reading "Couldn't save that — the change was undone."; the
 * same sentence, because it is the accurate one — the optimistic layer really
 * does put the value back.
 */

const NAV: Array<{ route: Route; label: string }> = [
  { route: "/", label: "Board" },
  { route: "/dashboard", label: "Dashboard" },
  { route: "/drive", label: "Drive" },
];

export default function App() {
  const s = useStore();
  const route = useRoute();

  useEffect(() => {
    markViewTransitionSupport();
    void restoreSession();
  }, []);

  // Nothing decided yet: no flash of the login screen for someone already
  // signed in, and no flash of the board for someone who is not.
  if (s.signedIn === null) return <div className="boot" aria-busy="true" />;
  if (!s.signedIn) return <LoginScreen />;

  return (
    <>
      <nav className="shell-nav">
        <div className="nav-tabs">
          {NAV.map(({ route: r, label }) => (
            <button
              key={r}
              className={route === r ? "on" : ""}
              aria-current={route === r ? "page" : undefined}
              onClick={() => navigate(r)}
            >
              {label}
            </button>
          ))}
        </div>
        <div className="nav-right">
          {/* A quiet "saving" hint rather than a spinner: with realtime this is
              usually gone before anyone could read it, and a spinner that
              flickers on every keystroke is worse than nothing. */}
          {s.pending > 0 && <span className="saving">saving…</span>}
          <button className="ghost" onClick={() => void signOut()}>
            Sign out
          </button>
          {/* The build, in the corner. On a phone with no devtools this is the
              only way to answer "did it actually update?" after a deploy. */}
          <span className="build-stamp" title="build">{__TS_BUILD__}</span>
        </div>
      </nav>

      {s.fatal && (
        <p className="banner banner-fatal" role="alert">
          {s.fatal} — reload to try again.
        </p>
      )}

      {/* Write failures. Each one is a rollback that already happened, so the
          wording says what was done, not what went wrong. */}
      {s.errors.map((e) => (
        <p key={e.id} className="banner" role="alert">
          Couldn&rsquo;t save that — the change was undone.
          <button className="banner-x" onClick={() => dismissWriteError(e.id)} aria-label="Dismiss">
            ×
          </button>
        </p>
      ))}

      {/* Keyed on the route so a swap really does remount the screen: that is
          what the .no-vt fallback animation needs. With the real View
          Transitions API it changes nothing, because the browser animates
          snapshots rather than the live DOM. */}
      <div className="page-swap" key={route}>
        {!s.booted ? (
          <div className="boot" aria-busy="true" />
        ) : route === "/dashboard" ? (
          <Dashboard />
        ) : route === "/drive" ? (
          <Drive />
        ) : route === "/calendar" ? (
          <main className="stub">
            <p className="label">Calendar</p>
            <h1>Deadlines &amp; events</h1>
            <p className="stub-note">
              Still a stub, exactly as it is in the Flutter app. The model and
              the collection exist; nothing writes to them yet.
            </p>
          </main>
        ) : (
          <Board />
        )}
      </div>
    </>
  );
}
