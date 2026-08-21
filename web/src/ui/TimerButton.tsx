/* The start/stop control.
 *
 * It is a real button rather than the whole row being tappable. The row carried
 * the toggle before, which meant there was no visible affordance, no hover
 * state worth the name, and no way to click a task without starting a timer on
 * it — fine while a row did nothing else, wrong as soon as rows have menus and
 * files and want opening.
 *
 * No hue, per tokens.css: colour means a person. Running is expressed by
 * inverting to filled ink, which is the loudest thing available that is not a
 * colour, and reads at a glance down the column.
 *
 * Stop is not styled as destructive. It ends a session, it does not delete one —
 * `--danger` is reserved for things that lose work.
 */
export function TimerButton({
  running,
  disabled,
  taskTitle,
  onToggle,
}: {
  running: boolean;
  disabled?: boolean;
  taskTitle: string;
  onToggle: () => void;
}) {
  return (
    <button
      className={"timer-btn" + (running ? " is-running" : "")}
      disabled={disabled}
      onClick={onToggle}
      /* The visible label is two words long; the accessible one names the task,
       * because "Stop" repeated nine times down a list tells you nothing. */
      aria-label={
        running ? `Stop your timer on ${taskTitle}` : `Start your timer on ${taskTitle}`
      }
      aria-pressed={running}
    >
      <span className="timer-glyph" aria-hidden="true">
        {running ? (
          <svg viewBox="0 0 10 10" width="9" height="9">
            <rect x="0" y="0" width="10" height="10" rx="1.5" fill="currentColor" />
          </svg>
        ) : (
          <svg viewBox="0 0 10 10" width="9" height="9">
            <path d="M1 0.5 L9.5 5 L1 9.5 Z" fill="currentColor" />
          </svg>
        )}
      </span>
      {running ? "Stop" : "Start"}
    </button>
  );
}
