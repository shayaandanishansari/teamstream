import { useId, useRef, type ReactNode } from "react";

/* A menu that animates open AND closed, and cannot be clipped.
 *
 * Why the native popover rather than an absolutely-positioned div: the menus
 * live inside `.tasks` and `.fold`, and BOTH of those need `overflow: hidden` —
 * the first to clip rows to the card's rounded corners, the second because the
 * 0fr->1fr fold depends on it. An absolutely positioned menu on the last row
 * would be cut off by its own container. `popover` renders in the top layer, so
 * no ancestor's overflow, z-index or transform can reach it.
 *
 * It also brings light-dismiss, Escape, and focus return with it, which is a
 * meaningful amount of fiddly code not written — and all of it behaviour the
 * Flutter canvas renderer could only approximate.
 *
 * Positioning is done here rather than with CSS anchor positioning, which is
 * still Chromium-only. Anchoring by `right` instead of `left` means we never
 * need to know the menu's own width, so it can be placed on `beforetoggle` —
 * before it has been laid out — with no first-frame flash in the wrong spot.
 */
export function MenuButton({
  label,
  children,
}: {
  label: string;
  children: ReactNode;
}) {
  const id = useId();
  const trigger = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);

  const place = (e: React.ToggleEvent<HTMLDivElement>) => {
    if (e.newState !== "open") return;
    const b = trigger.current?.getBoundingClientRect();
    const p = panel.current;
    if (!b || !p) return;

    const GAP = 4;
    p.style.left = "auto";
    p.style.right = `${Math.max(GAP, window.innerWidth - b.right)}px`;

    /* Flip above when there is not room below. Without this the last row's menu
     * on a phone opens off the bottom of the screen. 220px is a deliberate
     * over-estimate of the panel — being wrong upward only costs a flip that
     * was not strictly needed. */
    const below = window.innerHeight - b.bottom;
    if (below < 220 && b.top > below) {
      p.style.top = "auto";
      p.style.bottom = `${window.innerHeight - b.top + GAP}px`;
      p.style.transformOrigin = "bottom right";
    } else {
      p.style.bottom = "auto";
      p.style.top = `${b.bottom + GAP}px`;
      p.style.transformOrigin = "top right";
    }
  };

  return (
    <>
      <button
        ref={trigger}
        className="icon-btn"
        aria-label={label}
        popoverTarget={id}
      >
        &#8943;
      </button>
      <div
        ref={panel}
        id={id}
        popover="auto"
        className="pop menu"
        role="menu"
        onBeforeToggle={place}
      >
        {children}
      </div>
    </>
  );
}

/** One row of a menu. `closeOnClick` hides the popover imperatively, since a
 *  plain button inside a popover does not dismiss it. */
export function MenuItem({
  children,
  danger,
  onSelect,
}: {
  children: ReactNode;
  danger?: boolean;
  onSelect?: () => void;
}) {
  return (
    <button
      role="menuitem"
      className={danger ? "danger-item" : undefined}
      onClick={(e) => {
        e.currentTarget.closest<HTMLDivElement>("[popover]")?.hidePopover();
        onSelect?.();
      }}
    >
      {children}
    </button>
  );
}
