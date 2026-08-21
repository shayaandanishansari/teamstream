# Deploying TeamStream to the always-on Linux box

One sovereign binary (**PocketBase**) serves both the Flutter web app and the
API. A **Cloudflare Tunnel** on the same box publishes it at
`https://teamstream.shayaandanishansari.com`. PocketBase binds to localhost
only — the tunnel is the sole ingress, so the box is never exposed directly.

```
phone (any network) ──https──► Cloudflare ──tunnel──► box:  cloudflared ──► PocketBase(127.0.0.1:8090)
                                                                              ├─ / …… Flutter web app (pb_public/)
                                                                              └─ /api …… REST + realtime
```

Your brothers install nothing — they open the URL and "Add to Home Screen"
(installable PWA). The one honest tradeoff: Cloudflare terminates TLS, so it
sits in the data path. Swappable for the Tailscale mesh later without touching
the app.

---

## Step 0 — Prerequisite: domain on Cloudflare  ✅ already satisfied

`shayaandanishansari.com`'s DNS **and** apex site are already on Cloudflare, so
`cloudflared tunnel route dns` (Step 6) creates the `teamstream` subdomain CNAME
directly in your existing zone — **no nameserver change, and the apex site is
untouched** (it's just one new DNS record + a tunnel ingress). Skip to Step 1.

---

## Step 1 — Build the web app (on the Windows dev machine)

```powershell
# from repo root  C:\Drives\F\Work\TeamStream
powershell -ExecutionPolicy Bypass -File scripts\build-web.ps1
```

This runs `npm ci`, the palette check, the unit tests and `vite build`, then
copies `web\dist` into `backend\pb_public\`. Commit the result — the Linux box
has no node toolchain, so it receives the frontend via `git pull`, not scp:

```bash
git add backend/pb_public
git commit -m "Rebuild web app"
git push
```

---

## Step 2 — Clone the repo onto the Linux box

Create the install dir as a git clone, owned by your own login — **not**
`root` — so future `git pull` redeploys never need sudo (adjust the URL if
you use SSH):

```bash
sudo mkdir -p /opt/teamstream
sudo chown "$(whoami)" /opt/teamstream
git clone https://github.com/shayaandanishansari/teamstream /opt/teamstream
#   already cloned earlier?  ->  cd /opt/teamstream && git pull
```

`/opt/teamstream/backend/` now has `pb_public/`, `pb_migrations/`, and
`pb_hooks/` — everything except the (gitignored) PocketBase binary and the
(gitignored) `pb_data/` runtime state, which is created fresh by migrations.

---

## Step 3 — Get the matching Linux PocketBase binary (v0.39.9)

Version **must** match dev (0.39.9) so migrations + hooks behave identically.
The binary is gitignored — it never rides along with `git pull` — so fetch it
once, here, into the cloned `backend/` dir:

```bash
uname -m        # x86_64 -> amd64 ;  aarch64 -> arm64  (e.g. Raspberry Pi)

cd /opt/teamstream/backend
# amd64:
wget https://github.com/pocketbase/pocketbase/releases/download/v0.39.9/pocketbase_0.39.9_linux_amd64.zip
# --- or arm64: ---
# wget https://github.com/pocketbase/pocketbase/releases/download/v0.39.9/pocketbase_0.39.9_linux_arm64.zip

unzip -o pocketbase_0.39.9_linux_*.zip pocketbase
chmod +x pocketbase
rm pocketbase_0.39.9_linux_*.zip
```

---

## Step 4 — First run: migrate, seed, create admin

The service runs as a dedicated unprivileged **`teamstream`** user, but the
repo at `/opt/teamstream` stays owned by your own login (so `git pull` for
redeploys never needs sudo). Only the runtime DB directory (`pb_data/`,
created here) is locked down to the `teamstream` user:

```bash
sudo useradd --system --shell /usr/sbin/nologin teamstream || true

# teamstream needs to read the repo (git-managed files, no secrets) and
# execute the binary — grant read+traverse without changing the owner:
sudo chmod -R o+rX /opt/teamstream

# pb_data holds the SQLite DB (hashed passwords) — keep it private to teamstream:
sudo mkdir -p /opt/teamstream/backend/pb_data
sudo chown teamstream:teamstream /opt/teamstream/backend/pb_data
sudo chmod 700 /opt/teamstream/backend/pb_data
```

The app is gated by **one shared password** the three of you type in to sign in.
It's set here, at migrate time, via `TEAMSTREAM_PASSWORD` (min 8 chars). Choose
it now — this is the password you'll give Umair and Tawab.

```bash
# Apply migrations: creates collections + seeds the 3 members as auth accounts
# that all share THIS password. (env passed through sudo via `env`.)
sudo -u teamstream env TEAMSTREAM_PASSWORD='choose-a-shared-password' \
  /opt/teamstream/backend/pocketbase migrate up

# Create the admin account (for the /_/ dashboard — separate from the app login):
sudo -u teamstream /opt/teamstream/backend/pocketbase superuser create you@example.com 'a-strong-password'
```

> Changing the shared password later: do it from the `/_/` admin dashboard →
> members → edit each of the 3 → set a new password. (The seed only runs on a
> fresh DB; re-running migrations won't reset it.)

---

## Step 5 — Run PocketBase as a service

```bash
sudo cp /opt/teamstream/deploy/pocketbase.service /etc/systemd/system/pocketbase.service
#   (or copy the file from deploy/pocketbase.service in this repo)
sudo systemctl daemon-reload
sudo systemctl enable --now pocketbase
sudo systemctl status pocketbase          # should be active (running)
curl -s http://127.0.0.1:8090/api/collections/members/records | head   # 3 members
```

---

## Step 6 — Cloudflare Tunnel

```bash
# Install cloudflared (Debian/Ubuntu example):
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
sudo dpkg -i cloudflared.deb

cloudflared tunnel login                       # opens a browser; authorize the domain
cloudflared tunnel create teamstream           # prints a TUNNEL_ID + writes a creds .json
cloudflared tunnel route dns teamstream teamstream.shayaandanishansari.com
```

Put the config in place (edit `<TUNNEL_ID>` and the creds path to match what
`create` printed — `cloudflared tunnel login` as root writes to
`/root/.cloudflared/`):

```bash
sudo mkdir -p /root/.cloudflared
sudo cp /opt/teamstream/deploy/cloudflared/config.yml /root/.cloudflared/config.yml
sudo nano /root/.cloudflared/config.yml         # set <TUNNEL_ID>
```

Run it, then make it permanent:

```bash
cloudflared tunnel run teamstream               # test — Ctrl-C when it connects
sudo cloudflared service install                # runs on boot from ~/.cloudflared/config.yml
sudo systemctl status cloudflared
```

---

## Step 7 — Verify + hand it to your brothers

1. Open `https://teamstream.shayaandanishansari.com` — tap your name, enter the
   shared password → the board loads. (The session is remembered on-device, so
   the password is asked once per device, not every launch.)
2. Admin dashboard: `https://teamstream.shayaandanishansari.com/_/`.
3. On each phone: open the URL → browser menu → **Add to Home Screen**. It
   installs as an app (icon + full-screen) via the existing `manifest.json`.
4. Give Umair and Tawab the URL **and the shared password**.

---

## Step 8 — The file service (FastAPI on :8091)

New with the React port. PocketBase keeps auth, the tracker and realtime; this
owns file bytes only, because PocketBase's file field is a single multipart
request with no chunking or resume, and Cloudflare refuses a body over 100MB at
the edge regardless of what serves the route.

**Check what the box actually has before installing anything:**

```bash
python3 --version          # 3.11 or newer. Debian 11 / Ubuntu 20.04 ship 3.9.
df -h /srv                 # multi-GB files land here and stay
df -i /srv                 # INODES too: each upload makes a dir plus 3 files
```

```bash
sudo apt-get update
sudo apt-get install -y python3 python3-venv python3-dev ffmpeg
```

`ffmpeg` is optional — without it the service runs fine and simply offers no
video posters. It logs one line at boot naming what is missing.

**Venv, deliberately OUTSIDE the git checkout.** `/opt/teamstream` is a clone
owned by your login and made world-readable; a venv inside it means `.gitignore`
churn and a `git pull` racing a running service's `site-packages`.

```bash
sudo mkdir -p /opt/venvs && sudo chown teamstream:teamstream /opt/venvs
sudo -u teamstream python3 -m venv /opt/venvs/teamstream-files
sudo -u teamstream /opt/venvs/teamstream-files/bin/pip install -U pip
sudo -u teamstream /opt/venvs/teamstream-files/bin/pip install -r /opt/teamstream/files/requirements.txt
```

**The store — outside `pb_data/`, or every database backup becomes multi-GB:**

```bash
sudo mkdir -p /srv/teamstream-files/{blobs,thumbs,tmp}
sudo chown -R teamstream:teamstream /srv/teamstream-files
sudo chmod 750 /srv/teamstream-files
```

**The service:**

```bash
sudo cp /opt/teamstream/deploy/teamstream-files.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now teamstream-files
systemctl status teamstream-files --no-pager
curl -s localhost:8091/files/health
```

`/files/health` reports capabilities, free bytes, free inodes and the orphan
count. A non-zero orphan count is a job for a person — see `files/README.md`.

**Then the ingress.** `deploy/cloudflared/config.yml` already carries the rule;
copy it over the one on the box and restart the tunnel:

```yaml
ingress:
  - hostname: teamstream.shayaandanishansari.com
    path: ^/files(/|$)          # MOST SPECIFIC FIRST, or PocketBase swallows it
    service: http://127.0.0.1:8091
  - hostname: teamstream.shayaandanishansari.com
    service: http://127.0.0.1:8090
  - service: http_status:404
```

```bash
sudo cp /opt/teamstream/deploy/cloudflared/config.yml /root/.cloudflared/config.yml
sudo sed -i "s/<TUNNEL_ID>/$(sudo cloudflared tunnel list | awk '/teamstream/{print $1}')/" /root/.cloudflared/config.yml
sudo systemctl restart cloudflared
```

**Verify from a phone on mobile data, not just from the box:**

```
https://teamstream.shayaandanishansari.com/files/health   -> the file service
https://teamstream.shayaandanishansari.com/drive          -> the app, NOT a 404
https://teamstream.shayaandanishansari.com/               -> the app
```

That middle one is the check that matters. `/files/*` belongs to the API, so the
app's own file page is at **`/drive`** — a client route and an API prefix cannot
share a namespace. If `/drive` returns a FastAPI 404, the ingress rules are in
the wrong order.

Then upload something around 500MB end-to-end and seek a video mid-file. Chunks
are 8MB, well under Cloudflare's 100MB limit, and Cloudflare does not cap
response size, so large downloads already work.

---

## Step 9 — Cutover from Flutter to React

Do these as **two separate commits**. 32MB of canvaskit deletions mixed into the
diff that swaps the frontend makes the interesting change unreviewable.

```bash
# 1. drop canvaskit on its own
git rm -r --cached backend/pb_public
git commit -m "Remove the Flutter web build"

# 2. then the new build
powershell -ExecutionPolicy Bypass -File scripts\build-web.ps1
git add backend/pb_public && git commit -m "Ship the React build"
git push
```

Three things are already handled in `web/public/`, and all three are easy to
delete by accident:

- **`flutter_service_worker.js` is still served.** It is Flutter's 31-line
  *self-destructing* worker, kept deliberately rather than letting the URL 404. A
  registered service worker updates by re-fetching its own script; browsers *may*
  unregister it on a 404, but the behaviour is not uniform and it is not worth
  betting three phones on. A script that tears itself down is deterministic.
- **`purgeLegacy.ts` runs once per device**, unregistering every worker and
  clearing every cache. Safe unconditionally because the new app ships **no**
  service worker at all: offline is not a requirement for a tracker whose value
  is live shared state.
- **`manifest.json` pins `"id": "/"`.** Without it a PWA's identity is its
  `start_url`, and the old manifest used `"."` — so the phones would keep a dead
  icon and install a second one. The old icons are copied across as insurance.

On each phone: open the app, check the build stamp in the top-right, and
confirm the timer still runs.

**The stamp is the commit the build was made FROM, so it is the PARENT of the
commit that ships it** — the build has to run before its own commit can exist.
Compare against:

```bash
git log -1 --format=%h backend/pb_public   # the commit that shipped the build
git rev-parse --short HEAD~1               # what the stamp will say, if pb_public
                                           # was the most recent commit
```

Simplest check that is always right: `grep ts-build backend/pb_public/index.html`
on the box after pulling, and confirm the phone shows the same string. Matching
each other is the question; matching HEAD is not.

**If a phone is genuinely wedged:** long-press the home-screen icon → remove,
open the URL in the browser (a fresh navigation with no worker controlling it),
Add to Home Screen again. Worth knowing for iOS: Safari's storage and an
installed web app's storage have historically been separate, so clearing one does
not necessarily clear the other — `purgeLegacy` self-heals per context on next
launch, which means the fix lands once per context rather than once per phone.

---

## Redeploying after code changes

Everything (`pb_public/`, `pb_migrations/`, `pb_hooks/`) ships via git now —
no scp step. On the dev machine, rebuild + commit + push:

- **Frontend change:** re-run `scripts\build-web.ps1`, then
  `git add backend/pb_public && git commit && git push`.
- **New migration / hook:** just commit the changed files under
  `backend/pb_migrations/` or `backend/pb_hooks/` and push.
- **File service change:** commit under `files/` and push.

Then on the box:

```bash
cd /opt/teamstream && git pull
sudo systemctl restart pocketbase

# Only if files/ changed. If requirements.txt changed, install first --
# ProtectSystem=strict makes /opt read-only INSIDE the unit, so pip must run
# outside it, which is exactly what this does.
sudo -u teamstream /opt/venvs/teamstream-files/bin/pip install -r files/requirements.txt
sudo systemctl restart teamstream-files
curl -s localhost:8091/files/health
```

(Migrations apply on start; PocketBase must be restarted after pulling new
hooks or a new `pb_public/` build too, since it serves static files from
memory-mapped disk reads that are fine to just re-read, but a restart keeps
behavior predictable and picks up hook changes.)

## Notes / gotchas

- **Access = one shared password.** `members` is an auth collection; every data
  collection requires a signed-in request, so nobody with just the URL can read
  or write anything. Login identity is an internal email derived from the name
  (`shayaan@teamstream.local`) — users never see it. Honest limit: shared
  password = no per-person accountability, and if it leaks you rotate it for all
  three (admin dashboard → members). Verified locally end-to-end before ship.
- **Attachment FILES are the one exception to that gate.** The `attachments`
  *records* need auth like everything else, but the file bytes are served
  unauthenticated at `/api/files/...` — deliberately, because a protected file
  needs a short-lived token on every request and image previews would go blank
  the moment it expired. The URLs carry a random record id plus a randomised
  filename suffix, so they're unguessable, but anyone *handed* one can open it
  without logging in. Treat a pasted file link like a pasted file.
- **TWO stores now, with different rules — do not merge them.**
  - *Task attachments* live in `pb_data/storage/`, capped at **20 MB**, and
    cascade-delete with their task. Any backup that copies only `data.db`
    restores a board full of broken images: back up all of `pb_data/`, nightly.
    The cap is set in `1721700300_add_attachments.js` and mirrored in
    `web/src/data/actions.ts` (`MAX_ATTACHMENT_BYTES`) — raise them together or
    the client accepts a file the server then rejects.
  - *The shared drive* lives in `/srv/teamstream-files/`, has **no cap**, and
    nothing can hard-delete it. Back up `blobs/` **weekly**; exclude `thumbs/`,
    `tmp/` and `sessions.json`. Merging this into the nightly job would make
    every database backup multi-gigabyte, which is precisely why it is not
    inside `pb_data/`. Full table in `files/README.md`.

  These are different caps for different things, not an inconsistency to tidy
  away.
- **Realtime through the tunnel:** PocketBase realtime is SSE over HTTP —
  Cloudflare passes it through fine, so live "hot task" updates work remotely.
- **App URLs are relative, everywhere.** The React build talks to whatever
  origin served it, so the same build works via the domain, a LAN IP or a future
  mesh name with no rebuild. Local dev needs no `PB_URL` any more either: Vite
  proxies `/api` to :8090 and `/files` to :8091, so dev is same-origin exactly
  as production is. That is not only convenience — the `ts_files` cookie is
  origin-scoped, so a dev setup on a different port would behave differently
  from production in the one place it matters.
- **`/files/*` belongs to the API; the app's file page is `/drive`.** A client
  route and an ingress path rule cannot share a namespace.
- **The three-hour cap has two halves.** `close_runaway_timers.pb.js` sweeps
  every 10 minutes and writes `started_at + 3h`, *not* `now` — the client
  already treats a live entry as ending there, so the number never jumps. Its
  filter cutoff is formatted with a space rather than a `T` **on purpose**:
  PocketBase stores dates as `YYYY-MM-DD HH:MM:SS.sssZ` and compares filters
  lexicographically, and `' '` sorts below `'T'`, so an ISO cutoff matches every
  timestamp from the same date. That bug closed every live timer started today.
  `cd web && npm run verify:cap` is the fixture that catches it.
- **Swapping off Cloudflare later:** stop `cloudflared`, put Tailscale on the
  box + phones, point the domain (or MagicDNS) at the mesh IP. The app and
  PocketBase are untouched — only the ingress changes.
