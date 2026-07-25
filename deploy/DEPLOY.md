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

## Step 0 — Prerequisite: domain on Cloudflare (one-time, do this first)

Cloudflare Tunnel needs the domain's DNS managed by Cloudflare.

1. Create a free Cloudflare account, **Add a site** → `shayaandanishansari.com`.
2. Cloudflare gives you two nameservers. At your **registrar** (wherever you
   bought the domain), replace the nameservers with those two.
3. Wait for Cloudflare to show the domain **Active** (minutes to a few hours).

This does not disrupt anything else you host on the domain — Cloudflare imports
your existing records; you can review them before activating.

---

## Step 1 — Build the web app (on the Windows dev machine)

```powershell
# from repo root  C:\Drives\F\Work\TeamStream
powershell -ExecutionPolicy Bypass -File scripts\build-web.ps1
```

This runs `flutter build web --release` and copies the output into
`backend\pb_public\`. (Static files — safe to build on Windows, run on Linux.)

---

## Step 2 — Copy the backend to the Linux box

Ship the **backend** folder, but **not** the Windows binary and **not** dev data.
Create a clean install dir on the box (`/opt/teamstream`) containing:

```
/opt/teamstream/
├── pocketbase            # Linux binary — downloaded in Step 3, NOT the .exe
├── pb_public/            # the Flutter web build from Step 1
├── pb_migrations/        # schema + history + member seed  (rebuilds a fresh DB)
└── pb_hooks/             # history.pb.js
```

From the dev machine (adjust user/host), e.g. with scp:

```bash
scp -r backend/pb_public backend/pb_migrations backend/pb_hooks  you@BOX:/tmp/teamstream/
```

Then on the box:

```bash
sudo mkdir -p /opt/teamstream
sudo mv /tmp/teamstream/* /opt/teamstream/
```

> Do **not** copy `backend/pb_data/` — a fresh start is cleaner. The migrations
> rebuild all collections and seed the three members automatically. (If you ever
> *do* want the dev data, copy `pb_data/` too; the seed migration is idempotent.)

---

## Step 3 — Get the matching Linux PocketBase binary (v0.39.9)

Version **must** match dev (0.39.9) so migrations + hooks behave identically.

```bash
uname -m        # x86_64 -> amd64 ;  aarch64 -> arm64  (e.g. Raspberry Pi)

cd /opt/teamstream
# amd64:
wget https://github.com/pocketbase/pocketbase/releases/download/v0.39.9/pocketbase_0.39.9_linux_amd64.zip
# --- or arm64: ---
# wget https://github.com/pocketbase/pocketbase/releases/download/v0.39.9/pocketbase_0.39.9_linux_arm64.zip

unzip pocketbase_0.39.9_linux_*.zip pocketbase
chmod +x pocketbase
```

---

## Step 4 — First run: migrate, seed, create admin

```bash
sudo useradd --system --home /opt/teamstream --shell /usr/sbin/nologin teamstream || true
sudo chown -R teamstream:teamstream /opt/teamstream

# Apply migrations (creates collections + seeds Shayaan/Umair/Tawab):
sudo -u teamstream /opt/teamstream/pocketbase migrate up

# Create the admin account (for the /_/ dashboard):
sudo -u teamstream /opt/teamstream/pocketbase superuser create you@example.com 'a-strong-password'
```

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

1. Open `https://teamstream.shayaandanishansari.com` — the board loads, name
   picker shows Shayaan / Umair / Tawab.
2. Admin dashboard: `https://teamstream.shayaandanishansari.com/_/`.
3. On each phone: open the URL → browser menu → **Add to Home Screen**. It
   installs as an app (icon + full-screen) via the existing `manifest.json`.

---

## Redeploying after code changes

- **Frontend change:** re-run `scripts\build-web.ps1`, copy `pb_public/` to the
  box, `sudo systemctl restart pocketbase`.
- **New migration / hook:** copy `pb_migrations/` or `pb_hooks/`, then
  `sudo systemctl restart pocketbase` (migrations apply on start; PB must be
  restarted after editing hooks).

## Notes / gotchas

- **Realtime through the tunnel:** PocketBase realtime is SSE over HTTP —
  Cloudflare passes it through fine, so live "hot task" updates work remotely.
- **App URL is auto-resolving:** the web app talks to whatever origin served it
  (`Uri.base.origin`), so the same build works via the domain, a LAN IP, or a
  future mesh name with no rebuild. Local dev still uses
  `--dart-define=PB_URL=http://127.0.0.1:8090` (see `app/lib/config.dart`).
- **Swapping off Cloudflare later:** stop `cloudflared`, put Tailscale on the
  box + phones, point the domain (or MagicDNS) at the mesh IP. The app and
  PocketBase are untouched — only the ingress changes.
