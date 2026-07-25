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

This runs `flutter build web --release` and copies the output into
`backend\pb_public\`. (Static files — safe to build on Windows, run on Linux.)

---

## Step 2 — Clone the repo to /opt/teamstream

The box has no Flutter — but it doesn't need it. The built web app (`pb_public/`),
the migrations, and the hooks are all committed, so a plain clone gets everything.
PocketBase runs out of the `backend/` subfolder.

```bash
sudo git clone https://github.com/shayaandanishansari/teamstream.git /opt/teamstream
#   already cloned earlier?  ->  cd /opt/teamstream && sudo git pull
```

The PocketBase workdir is **`/opt/teamstream/backend/`** — it already holds
`pb_public/`, `pb_migrations/`, `pb_hooks/`. Only the Linux binary and the
runtime `pb_data/` get added on the box (next steps). `pb_data/` is gitignored,
so a fresh DB is built from the migrations on first run.

---

## Step 3 — Get the matching Linux PocketBase binary (v0.39.9)

Version **must** match dev (0.39.9) so migrations + hooks behave identically.

```bash
uname -m        # x86_64 -> amd64 ;  aarch64 -> arm64  (e.g. Raspberry Pi)

cd /opt/teamstream/backend
# amd64:
wget https://github.com/pocketbase/pocketbase/releases/download/v0.39.9/pocketbase_0.39.9_linux_amd64.zip
# --- or arm64: ---
# wget https://github.com/pocketbase/pocketbase/releases/download/v0.39.9/pocketbase_0.39.9_linux_arm64.zip

unzip -o pocketbase_0.39.9_linux_*.zip pocketbase
chmod +x pocketbase
```

---

## Step 4 — First run: migrate, seed, create admin

The app is gated by **one shared password** the three of you type in to sign in.
It's set here, at migrate time, via `TEAMSTREAM_PASSWORD` (min 8 chars). Choose
it now — this is the password you'll give Umair and Tawab.

```bash
sudo useradd --system --home /opt/teamstream --shell /usr/sbin/nologin teamstream || true
sudo chown -R teamstream:teamstream /opt/teamstream

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

## Redeploying after code changes

- **Frontend change:** re-run `scripts\build-web.ps1`, copy `pb_public/` to the
  box, `sudo systemctl restart pocketbase`.
- **New migration / hook:** copy `pb_migrations/` or `pb_hooks/`, then
  `sudo systemctl restart pocketbase` (migrations apply on start; PB must be
  restarted after editing hooks).

## Notes / gotchas

- **Access = one shared password.** `members` is an auth collection; every data
  collection requires a signed-in request, so nobody with just the URL can read
  or write anything. Login identity is an internal email derived from the name
  (`shayaan@teamstream.local`) — users never see it. Honest limit: shared
  password = no per-person accountability, and if it leaks you rotate it for all
  three (admin dashboard → members). Verified locally end-to-end before ship.
- **Realtime through the tunnel:** PocketBase realtime is SSE over HTTP —
  Cloudflare passes it through fine, so live "hot task" updates work remotely.
- **App URL is auto-resolving:** the web app talks to whatever origin served it
  (`Uri.base.origin`), so the same build works via the domain, a LAN IP, or a
  future mesh name with no rebuild. Local dev still uses
  `--dart-define=PB_URL=http://127.0.0.1:8090` (see `app/lib/config.dart`).
- **Swapping off Cloudflare later:** stop `cloudflared`, put Tailscale on the
  box + phones, point the domain (or MagicDNS) at the mesh IP. The app and
  PocketBase are untouched — only the ingress changes.
