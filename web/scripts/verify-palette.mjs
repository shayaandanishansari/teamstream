/* Proves every contrast number written into src/styles/tokens.css.
 *
 * Run it after touching any colour:  node scripts/verify-palette.mjs
 * Exits non-zero if a required pairing regresses, so it can go in CI later.
 *
 * The values are duplicated here rather than parsed out of the CSS on purpose:
 * this script is the thing that decides whether a colour is allowed, so it
 * should fail loudly when someone edits the CSS without editing it. A parser
 * would silently bless whatever it found.
 */

const lin = (c) => {
  c /= 255;
  return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
};

const luminance = (hex) => {
  const h = hex.replace("#", "");
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
};

export const ratio = (a, b) => {
  const [hi, lo] = [luminance(a), luminance(b)].sort((p, q) => q - p);
  return (hi + 0.05) / (lo + 0.05);
};

const THEMES = {
  light: {
    ground: "#FBFAF8", surface: "#FFFFFF", sunken: "#F1EEE9",
    ink: "#1B1A17", ink2: "#56534C", ink3: "#6E6A62",
    line: "#E5E1D9", danger: "#B3261E",
  },
  dark: {
    ground: "#121312", surface: "#1C1D1C", sunken: "#0B0C0B",
    ink: "#EDEAE4", ink2: "#A8A49B", ink3: "#8A867E",
    line: "#2E2F2E", danger: "#FF9A8F",
  },
};

/* Seeded in backend/pb_migrations/1721700200_seed_members.js. Reported, never
 * asserted: these are database values a person can change, and the design does
 * not depend on them clearing anything — that is what the ring is for. */
const MEMBERS = { Shayaan: "#00A896", Umair: "#FFB238", Tawab: "#3A5AFF" };

let failed = 0;

function check(label, fg, bg, need) {
  const r = ratio(fg, bg);
  const ok = r >= need;
  if (!ok) failed++;
  console.log(
    `  ${(ok ? "PASS" : "FAIL").padEnd(4)} ${r.toFixed(2).padStart(6)}:1  ` +
    `(need ${need})  ${label}`
  );
}

for (const [name, t] of Object.entries(THEMES)) {
  console.log(`\n=== ${name} ===`);
  for (const bg of ["ground", "surface", "sunken"]) {
    check(`ink   on ${bg}`, t.ink, t[bg], 7);     // body text: AAA
    check(`ink-2 on ${bg}`, t.ink2, t[bg], 4.5);  // secondary: AA
    check(`ink-3 on ${bg}`, t.ink3, t[bg], 4.5);  // labels: AA, no exemption
  }
  check("danger on ground (used as TEXT)", t.danger, t.ground, 4.5);
}

console.log("\n=== member colours as bare fills — why the ring exists ===");
for (const [who, c] of Object.entries(MEMBERS)) {
  const l = ratio(c, THEMES.light.surface);
  const d = ratio(c, THEMES.dark.surface);
  console.log(
    `  ${who.padEnd(8)} ${c}  light ${l.toFixed(2)}:1 ${l >= 3 ? "ok" : "under 3:1"}` +
    `   dark ${d.toFixed(2)}:1 ${d >= 3 ? "ok" : "under 3:1"}`
  );
}

console.log(
  failed
    ? `\n${failed} required pairing(s) FAILED — fix the colour or the token comment.`
    : "\nAll required pairings pass."
);
process.exit(failed ? 1 : 0);
