# TeamStream — React + FastAPI port plan

Written 2026-08-20, in `Marketing/` for convenience. **Move this to
`C:\Drives\F\Work\TeamStream\plan.md` before starting.** Nothing in it belongs
to the marketing sprint.

Three decisions, already made — this document is the how, not the whether:

1. **Drop Flutter, rebuild the frontend in React.**
2. **FastAPI + PocketBase hybrid.** PocketBase keeps auth, the task tracker and
   realtime. FastAPI owns file bytes only.
3. **The file explorer is lifted from `video_editor`**, widened from video to
   all file types.

---

## 1. Why, in one place

So the reasoning survives the rewrite.

**Flutter goes because it is the wrong renderer for this product, not because
of taste.** Flutter web paints to canvas — since 3.29 the HTML renderer is gone
and there is no escape hatch — so text selection, right-click, autofill, native
scroll and accessibility are all approximations. No amount of restyling reaches
any of it. The built bundle in `backend/pb_public/` is **36MB, of which 32MB is
canvaskit**, committed to git because the box has no Flutter toolchain; a
browser pulls one wasm variant plus a 2.8MB `main.dart.js`, so **first load is
6–10MB for a task board**. React lands in the low hundreds of KB.

`app/android` and `app/ios` exist but are never used — `DEPLOY.md` says the team
"install nothing — they open the URL and Add to Home Screen." The one thing
Flutter buys is not being cashed in.

**The port is cheap now and never cheaper.** 4,008 lines of Dart, and it splits:

| | Lines | Fate |
|---|---|---|
| `ui/` — `board_screen` 1193, `dashboard_screen` 856, `app_shell` 217, `pick_name_screen` 229, `calendar_screen` 24, `work_folding` 37 | ~2,550 | rewritten |
| `models/` + `data/` + `theme` + `identity` + `config` | ~1,450 | ports conceptually |

For scale: `video_editor`'s frontend carries a **video editor** — scrubbing
timeline, segment splitting, keyboard transport, background jobs — in **1,731
lines** of Preact. This is not harder than something already shipped in this
stack.

**FastAPI joins because PocketBase cannot do large uploads.** Its file field is
one multipart request — no chunking, no resume. And the 100MB ceiling is
Cloudflare's, enforced at the edge before the box sees the request, so it binds
regardless of what serves the route. Chunked upload against a filesystem is
~100 lines of Python and gives resume for free, which multi-GB over a home
uplink needs anyway.

---

## 2. Architecture

**Now**

```
cloudflared ──► PocketBase :8090
                  ├─ /      pb_public/  (Flutter web, 36MB)
                  └─ /api   REST + realtime + files (20MB cap)
```

**After**

```
cloudflared ──┬─ /files/* ──► FastAPI :8091 ──► /srv/teamstream-files/
              └─ /*       ──► PocketBase :8090
                                ├─ /      pb_public/  (React build)
                                └─ /api   REST + realtime + metadata
```

**The split rule:** PocketBase owns *records and identity*. FastAPI owns
*bytes*. A file has a row in PocketBase and a blob under FastAPI, and neither
service duplicates the other's job.

---

## 3. Phase 0 — decide these before writing code

- [x] **Visual direction.** — DONE, `web/src/styles/tokens.css`.
      **The rule: colour means a person, and nothing else.**

      This was forced by the data rather than chosen. The three "accents" the
      Flutter theme used are *the same three values* seeded as member colours in
      `1721700200_seed_members.js` — teal `#00A896` is Shayaan, amber `#FFB238`
      is Umair, cobalt `#3A5AFF` is Tawab. A teal button therefore reads as a
      person. So the UI gives up chroma entirely: structure and interaction are
      ink, and the only coloured things on screen are people.

      The measured trap, exactly as predicted above: teal fails **both**
      directions — 2.84:1 as text on the old background, and 2.98:1 with white
      on it. Amber is 1.71:1. The shipping app has been unreadable in both
      directions the whole time.

      Worse, the three colours *disagree* about what text they need — ink on
      teal 5.71 ✓, on amber 9.46 ✓, on cobalt 3.31 ✗ (cobalt wants white, 5.14)
      — and members can edit their colour in the admin UI, so no pairing is
      safe. Hence: **text is never placed on a member colour and a member colour
      is never used as text.** It appears only as a fill inside a hairline ring,
      at non-text sizes. The ring is load-bearing, not decoration: bare on a
      light surface, teal is 2.98:1 and amber 1.80:1, both under the 3:1 a UI
      element needs.

      Ink scale, both themes, every pairing computed and asserted by
      `web/scripts/verify-palette.mjs` (`npm run verify`, exits non-zero on a
      regression). Body AAA, secondary and labels AA — labels included, because
      an eyebrow nobody can read is a missing label rather than a subtle design.
      Type cut from three families to two; the serif display face is gone, and
      anything that counts gets mono with tabular figures so a ticking timer's
      digits hold their column. Fonts are self-hosted via `@fontsource`, not
      linked from Google — a PWA on a home uplink should not need a CDN to
      render text. **Nothing is inherited from Stu, and nothing is inherited
      from the old theme either.**
- [x] **Per-file cap.** — DECIDED: **no hard cap**, soft warning above ~2GB,
      disk is the real limit. Adopted as suggested; revisit only if the free-disk
      answer below comes back small.
- [ ] **Free disk on the VPS.** Multi-GB files land in a real directory and
      stay. Check before promising yourself video hosting.
- [ ] **Does the board keep its current layout?** — ANSWERED: **no. The
      complaint is the LOOK.** So the board is redesigned *before* it is ported,
      exactly as this bullet warns. Phase 3 does not begin with a translation of
      `board_screen.dart`; it begins with a layout decision. The 1,193 lines are
      a source of requirements, not a template.

---

## 4. Phase 1 — React skeleton

Vite + React + TypeScript. Build it as a fresh `web/` alongside `app/` until
parity — **keep Flutter serving from `pb_public/` until React is genuinely
better.** The cutover is one directory, so there is no risky moment.

**Lift the architecture from `video_editor/video_editor/app/ui/` wholesale.**
Its `CLAUDE.md:186` documents four rules; three apply here verbatim:

- **One store.** `store.js` is a plain object, a `Set` of listeners, and
  `set()`, with writes coalesced onto a microtask so one interaction renders
  once. Copy the shape. It replaces Riverpod.
- **Components read the store and call `actions.js`. They never fetch.** This
  is exactly what `optimistic_repo.dart` (510 lines) already is — the port is a
  translation, not a redesign.
- **Hot values live outside the store.** `clock.js` keeps the playhead out
  because `timeupdate` fires 4×/sec and would re-render the whole editor for a
  number three things care about. **TeamStream's running-task timer has the
  identical problem** — same solution: subscribe to a derived value.
- ~~The server owns the model~~ — does not apply; PocketBase is the model.

**`api.js` ports as-is** (22 lines): unwrap errors once, not at 20 call sites.

**Do NOT copy the polling.** `actions.js`'s `poll` / `pollJobs` exist because
video_editor's server pushes nothing. PocketBase gives realtime SSE, and
`DEPLOY.md:229` confirms it passes through the tunnel. That layer disappears
rather than ports.

**Copy, don't share.** `video_editor` is a separate repo with its own upstream
history. No submodule, no symlink — take the files and let them diverge.

**`config.dart` mostly evaporates.** Its same-origin resolution is what a
browser does natively; use relative URLs. Keep one constant for the dev-mode
PocketBase origin.

---

## 5. Phase 2 — models and realtime

Port from `app/lib/models/` — all small, all pure:

| Dart | Lines | Note |
|---|---|---|
| `member.dart` | 8 | trivial |
| `event.dart` | 18 | |
| `work.dart` | 22 | |
| `time_math.dart` | 30 | pure functions — port first, test first |
| `time_entry.dart` | 31 | |
| `task.dart` | 53 | |
| `attachment.dart` | 103 | **keep `isImageName` / `extension` / `prettySize`** — reused by the new file explorer |

Collections already in `pb_migrations/`: `members`, `works`, `tasks`,
`time_entries`, `events`, `attachments`, `history`.

### The 3-hour cap (new rule)

**A timer left running closes itself after three hours.** Done in
`web/src/models/timeMath.ts`, tested, and wired into the board prototype.

Two decisions inside it are worth more than the number:

- **It applies only to entries nobody stopped.** An entry with an `ended_at` is
  a person having pressed stop, and that is the truth about their day. Capping
  it would silently delete an hour from someone who genuinely worked four. The
  rule is "a timer stops itself", not "no session may exceed three hours" — and
  the difference showed up as two pre-existing tests failing the moment the
  stricter version went in.
- **It is enforced in the arithmetic, not just at the moment of stopping.**
  Nothing may be running to do the stopping — close the laptop and no browser is
  awake to notice, so the row just keeps having no `ended_at`. `effectiveEnd`
  therefore treats a live entry as ending at `start + 3h` whether or not that is
  written yet, and `overlapWithinMs` uses it, so a forgotten timer cannot
  inflate the board, a task total, or the dashboard's day and week windows even
  before anything has closed it. When a close is finally written it writes
  `start + 3h` rather than `now`, so the number never jumps.

**Still needed: the server-side sweep.** A browser can only close a timer while
a browser is open; a PocketBase hook is what makes it true when nobody is
looking. It belongs with the backend wiring below, and it writes the same value
the client does, so it does not matter which gets there first. **`backend/` has
deliberately not been touched — that is the running system the team is using
today.**

**Prove realtime + auth from JS before building any screen.** PocketBase's JS
SDK is its first-class client, better maintained than the Dart one. If
subscriptions and the shared-password login work, the rest is drawing.

**Consider TanStack Query.** Optimistic mutation with rollback is native to it
and may absorb most of `optimistic_repo.dart`'s 510 lines. It is possible to
come out of this with *less* code than you started with.

---

## 6. Phase 3 — rebuild the screens

Order: `app_shell` → `board_screen` → `dashboard_screen` → `pick_name_screen` →
`calendar_screen` (24 lines, a stub — leave last).

Board first because it is 1,193 lines and carries the product. If the board
feels right in React the decision is validated; if it doesn't, stop before
spending the rest.

**The board is redesigned, not ported** (Phase 0 answered: the complaint is the
look). A prototype with fake data covering every state is in
`web/src/prototype/` — run `npm run dev` and switch to "board". Four changes,
each fixing something measured in the Dart rather than restyled:

1. **No state-dependent fills.** The old `_TaskTile` chose one of four
   backgrounds — done / hot / has-history / fresh — so a scan down the list
   crossed four colours. And "hot" was `bg = teal, fg = white`: **2.98:1, a
   fail.** The board's most important state was its least readable. Every row
   now sits on one surface; state is carried by the rail, weight and the timer.
2. **A left identity rail answers "who".** Full row height, one segment per
   contributor in first-touch order, live segments solid and pulsing, past ones
   faded. You read the board down its left edge: colour is who, motion is now.
   This also fixes something the old design *could not express* — two people
   live on one task, because one background cannot be two colours. `t1` in the
   prototype's fixture is exactly that case.
3. **Critical is ink, not amber** — amber is Umair. Any hue there names a
   person, so importance is carried by contrast (16.68:1) instead.
4. **"4 left" replaces "43%".** The old header carried a bar *and* a
   percentage: two encodings of one number, and a percentage of seven tasks is
   false precision. The count states the size of the job that remains; the bar
   drops to a hairline glance.

Also fixed in passing: `_Dot` defaulted an unknown member to `'#00A896'`, which
is *Shayaan's* colour — a missing member silently rendered as him. Unknown
members are now ink.

Two things the redesign adds that colour alone cannot carry: the rail has an
`aria-label` naming who is on the task and whether they are working now, and a
second person's presence is also stated in words on the row. A pulsing colour is
not information everyone can receive.

### Motion

Everything that opens, closes or swaps is animated, and it is **done in CSS with
no animation library** — the whole motion layer costs about 2.4KB, which matters
when a small bundle is half the reason we left Flutter. Durations and easings are
tokens (`--dur-*`, `--ease-*`), graded by distance travelled, so a chip and a
whole section feel like one product rather than forty hand-typed numbers that
almost agree. Nothing is slower than 320ms.

Three mechanisms, in `web/src/styles/motion.css`:

- **`.fold`** — open/close to auto height via `grid-template-rows: 0fr -> 1fr`.
  `height: auto` has never been animatable; a hardcoded `max-height` guesses
  wrong and JS measurement costs a layout read per toggle. The grid resolves to
  the real height every frame, for any content, with no measuring.
  `interpolate-size` would be tidier but is Chromium-only.
- **`.pop`** — enter *and exit* via `@starting-style` + `transition-behavior:
  allow-discrete`. React unmounts immediately, so an exit animation normally
  needs a library holding the element alive; transitioning `display` removes
  that need entirely.
- **`::view-transition`** — page and theme swaps through the native View
  Transitions API (`motion/viewTransition.ts`). React 19.2 stable does not
  export `<ViewTransition>` — that is experimental-build only — so this drives
  the browser API directly. `flushSync` is required, or React batches the update
  to after the callback and the browser screenshots an unchanged DOM.

**Menus are native `popover`s.** Not a style choice: `.tasks` needs
`overflow: hidden` to clip rows to the card's corners and `.fold` needs it for
the animation, so an absolutely-positioned menu on the last row would be cut in
half by its own container. The top layer escapes every ancestor's overflow, and
brings light-dismiss, Escape and focus return with it. Positioning is done in JS
because CSS anchor positioning is still Chromium-only; anchoring by `right`
rather than `left` means the panel's own width is never needed, so it can be
placed before layout with no first-frame flash.

Two things kept honest: JS reads its unmount delay from `--dur-fast` via
`motion/duration.ts` rather than hardcoding a matching number, so retuning a
token cannot leave rows vanishing mid-fade; and everything is switched off under
`prefers-reduced-motion`, including view transitions, which the UA animates
rather than us and so must be disabled explicitly. The live pulse falls back to
a static ring — it carries meaning, so it degrades rather than disappears.

---

## 7. Phase 4 — the FastAPI file service

### Storage layout

Put it **outside `pb_data/`**. `DEPLOY.md:224` says back up all of `pb_data/`;
if blobs live there, every DB backup becomes a multi-GB copy.

```
/srv/teamstream-files/
  blobs/<file_id>/<original-name>      the file, under its REAL name
  blobs/<file_id>/meta.json            name, size, mime, uploader, folder, ts
  thumbs/<file_id>-<w>.jpg             generated, disposable
  tmp/<upload_id>.part                 in-flight uploads
```

**`meta.json` is deliberate redundancy.** PocketBase stores blobs at
`pb_data/storage/<collectionId>/<recordId>/<randomised-name>` — lose `data.db`
and you have a heap of files you cannot map back to names or owners. Real
filenames plus a sidecar means the store is fully recoverable with the database,
the app and the tunnel all gone. That is the entire point of this project.

### Chunked upload protocol

Chunk size **8–16MB** — far under Cloudflare's 100MB request ceiling.

```
POST   /files/uploads              {name, size, mime, folder} -> {upload_id}
GET    /files/uploads/{id}         -> {received}            # for resume
PUT    /files/uploads/{id}?offset= <bytes> -> {received}    # append
POST   /files/uploads/{id}/finish  -> {file_id}             # fsync, move, create PB record
DELETE /files/uploads/{id}                                  # abandon
```

Append to `tmp/<id>.part`, verify `offset == received` before writing (refuse
otherwise — never seek), then fsync and rename into `blobs/`. Rename on the same
filesystem is atomic, so a file is either absent or complete, never half-written.

Sweep `tmp/` for parts untouched >24h.

### Download

```
GET /files/<file_id>                 the blob, honouring Range
GET /files/<file_id>/thumb?w=480     generated thumbnail
```

**Range/206 is non-negotiable for video** — without it the browser cannot seek
at all. Starlette's `FileResponse` gained Range support in recent versions:
**check yours before porting anything.** If it lacks it,
`video_editor/app/server.py:262` (`_send_file`) is the reference, and it handles
the two bits people miss — suffix ranges (`bytes=-500`) and a proper 416 with
`Content-Range: bytes */<size>`.

Cloudflare does not cap response size, so large downloads through the tunnel
already work.

### Thumbnails — the one genuinely new piece

`video_editor`'s `library.poster()` is ffmpeg, video-only. Widen it to a
dispatch on mime:

| Type | Tool |
|---|---|
| image | Pillow resize |
| video | ffmpeg frame grab (lift the existing call) |
| pdf | first page via `pypdfium2` |
| anything else | no thumb — the UI shows an extension chip |

Cache to `thumbs/<id>-<w>.jpg`, generate on demand, and never block a listing on
generation. This is the part with no existing code — budget for it.

### Auth, and the trap to dodge

FastAPI **verifies tokens by asking PocketBase**, not by reimplementing JWT
checks. Forward the token to `/api/collections/members/auth-refresh` and cache
the answer for ~60s.

**Read `DEPLOY.md:216` first.** PocketBase serves attachment bytes
unauthenticated *on purpose*, because a protected file needs a short-lived token
on every request and `<img>` previews go blank the moment it expires. The file
service hits the identical wall — **`<img src>` and `<video src>` cannot send an
`Authorization` header.**

**Fix it with a cookie.** Cookies ride along on `<img>` / `<video>` requests
automatically:

```
POST /files/session   Authorization: <PB token>
  -> Set-Cookie: ts_files=<opaque>; HttpOnly; Secure; SameSite=Lax; Path=/files
```

React calls this once after login. GETs authenticate by cookie, writes by
header. This is strictly better than what PocketBase does today, and it is
available only because you are writing the service yourself.

### Deletion policy

**Never destroy anything.** Two rules, both cheap:

- **Same name uploaded twice = a new record**, newest first, old one intact —
  a server-side version history for free.
- **Delete sets `deleted_at`**; the blob stays on disk. Reaping is a manual
  chore, run deliberately, never wired into the app.

This is the property the whole design exists for: local files are never touched
because nothing here can reach them, and server files are never destroyed
because nothing is wired to destroy them.

---

## 8. Phase 5 — the file explorer UI

Lift from `video_editor/app/ui/`:

- **`Library.js`** (40 lines) — the folder grid, empty states, click-through.
- **`Folder.js`** (93 lines) — the file card. Already the right shape: poster,
  corner badges, name with a rename button, size, a tag row. Swap
  "duration / silent / 1080×1920 @ 60fps" for "PDF / 4.2 MB / Umair, Tuesday".
- **`bits.js`** (28 lines) — `Shot` and `Thumb` already degrade a failed
  thumbnail to one grey box instead of taking out the grid. Keep that
  behaviour; with mixed file types it will fire more often.
- **`dialogs.js`** (248 lines) — preview and rename dialogs.

**Folders: one flat text field**, not a tree. A `folder` string plus a filter
chip is 95% of the value; nesting means rename/move/orphan handling, which is
the layer this project exists to avoid.

**Show uploader and timestamp on every row, newest first.** The honest cost of a
drop-box over real sync is ambiguity about which copy is current — this is the
mitigation, and `members` + `created` are already first-class fields on the
existing attachments design.

**Upload UI:** drag-and-drop onto the grid, per-file progress from the chunk
loop, resume on reconnect, and a visible "3 of 47 chunks" for the multi-GB case.

---

## 9. Phase 6 — deploy

Changes to `deploy/`:

1. **Second systemd unit** — `teamstream-files.service`, modelled on
   `pocketbase.service`: `User=teamstream`, `Restart=always`,
   `--host 127.0.0.1 --port 8091`, never exposed directly.
2. **cloudflared ingress gains a path rule.** Most specific first:

   ```yaml
   ingress:
     - hostname: teamstream.shayaandanishansari.com
       path: ^/files/
       service: http://127.0.0.1:8091
     - hostname: teamstream.shayaandanishansari.com
       service: http://127.0.0.1:8090
     - service: http_status:404
   ```
3. **`scripts/build-web.ps1` becomes a Vite build**, still copying into
   `backend/pb_public/`. Everything downstream in `DEPLOY.md` is unchanged.
4. **`run.bat` gains a third window** for uvicorn.
5. **Two backup schedules.** `pb_data/` stays small and frequent;
   `/srv/teamstream-files/` is large and slow. Do not merge them.
6. **Python on the box** — it has no Flutter toolchain and may have no venv
   either. Check before Step 1.
7. **Drop 32MB of canvaskit from the working tree** once Flutter is gone.
   History keeps it; the checkout does not have to.

---

## 10. Traps, collected

- **The 100MB limit is Cloudflare's, not PocketBase's.** Enforced at the edge.
  No backend change raises it — only chunking, or swapping the ingress.
- **`<img>` cannot send an auth header.** Cookie, not bearer token.
- **Range/206 or no video seeking.** Not "worse" — none.
- **`maxSize` lives in two places today** (the migration and `config.dart`). If
  any cap survives, keep it in one place and have the other read it.
- **`attachments.task` has `cascadeDelete: true`** — correct for a task's
  screenshots, fatal for a shared drive. The new `files` collection must be
  separate, with no cascade.
- **Blobs outside `pb_data/`**, or backups balloon.
- **Cloudflare's Free terms** discourage bulk non-HTML distribution. Three
  people is not what they police; routine multi-GB traffic is the point to move
  to Tailscale — `DEPLOY.md:237` says the app and PocketBase are untouched, only
  the ingress changes.
- **Preact differs from React in syntax, not architecture.** htm's no-build
  property is load-bearing for `video_editor` (`CLAUDE.md:181`: it must survive
  being dropped on a machine with no node). TeamStream already builds. Take the
  architecture, drop the constraint.

---

## 11. Open questions

1. **Free disk on the VPS?** — STILL OPEN. The only thing blocking Phase 4's
   storage sizing. Needs `df -h /srv` on the box.
2. ~~Is the complaint about the board its *look* or its *feel*?~~ — **LOOK.**
   Design the board first, then port. See Phase 0 above.
3. ~~Does anything still need native Android/iOS?~~ — **PWA is final.**
   `app/android` (19 files) and `app/ios` (40 files) deleted; git history keeps
   them. Deletion staged, not yet committed.
4. ~~Shared password, or per-person accounts?~~ — **Shared password stays.**
   The honest limit at `DEPLOY.md:210` is accepted rather than fixed: the
   uploader name on a file is self-declared, because anyone who knows the
   password can log in as any of the three. Worth writing on the file explorer's
   own terms — "uploaded by Umair" means "whoever was signed in as Umair", and
   the file store should not imply more certainty than the login provides.

---

## 12. Order of work

```
Phase 0  decisions                      ── DONE bar 2 (disk, board look/feel)
Phase 1  React skeleton + store/api     ── scaffolded; store/api still to lift
Phase 2  models + realtime proof        ── time_math ported+tested; rest to do
                                           STOP HERE if realtime misbehaves
Phase 3  board                          ── the real test; validate before continuing
         dashboard, identity, calendar
Phase 4  FastAPI: chunked up, range down, thumbs, cookie auth
Phase 5  file explorer UI               ── lifted from video_editor
Phase 6  deploy: 2nd unit, ingress, backups
```

Flutter keeps serving from `pb_public/` until Phase 3 looks better than it does.
Build files last: they are native to the new stack, and building them in Flutter
first would be paying twice for the hardest thing to port.
