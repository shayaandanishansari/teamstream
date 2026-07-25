#!/usr/bin/env bash
# TeamStream — always-on box setup.
#
# Run this in a REAL terminal (local console or SSH), not through Claude Code —
# it needs an actual TTY for `sudo` and for the password prompts below, which
# are typed here and never leave this terminal.
#
#   bash deploy/setup.sh
#
# Safe to re-run: each step skips itself if already done.

set -euo pipefail

REPO_URL="https://github.com/shayaandanishansari/teamstream"
INSTALL_DIR="/opt/teamstream"
PB_VERSION="0.39.9"

echo "== 1/6 — clone or update $INSTALL_DIR =="
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "already cloned — pulling latest"
  git -C "$INSTALL_DIR" pull
else
  sudo mkdir -p "$INSTALL_DIR"
  sudo chown "$(whoami)" "$INSTALL_DIR"
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

echo
echo "== 2/6 — PocketBase binary (v$PB_VERSION) =="
if [ ! -x "$INSTALL_DIR/backend/pocketbase" ]; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) PB_ARCH=amd64 ;;
    aarch64) PB_ARCH=arm64 ;;
    *) echo "Unsupported arch: $ARCH"; exit 1 ;;
  esac
  TMP=$(mktemp -d)
  wget -q "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_${PB_ARCH}.zip" -O "$TMP/pb.zip"
  unzip -o -q "$TMP/pb.zip" pocketbase -d "$INSTALL_DIR/backend"
  chmod +x "$INSTALL_DIR/backend/pocketbase"
  rm -rf "$TMP"
  echo "downloaded"
else
  echo "already present — skipping"
fi

echo
echo "== 3/6 — teamstream service user + pb_data lockdown =="
if ! id teamstream &>/dev/null; then
  sudo useradd --system --shell /usr/sbin/nologin teamstream
fi
sudo chmod -R o+rX "$INSTALL_DIR"
sudo mkdir -p "$INSTALL_DIR/backend/pb_data"
sudo chown teamstream:teamstream "$INSTALL_DIR/backend/pb_data"
sudo chmod 700 "$INSTALL_DIR/backend/pb_data"

echo
echo "== 4/6 — migrate + seed + admin account =="
if [ -z "$(sudo ls -A "$INSTALL_DIR/backend/pb_data" 2>/dev/null)" ]; then
  echo "Fresh DB — set the shared password the three of you will log in with."
  read -r -s -p "Shared password (min 8 chars): " TEAMSTREAM_PASSWORD
  echo
  sudo -u teamstream env TEAMSTREAM_PASSWORD="$TEAMSTREAM_PASSWORD" \
    "$INSTALL_DIR/backend/pocketbase" migrate up
  unset TEAMSTREAM_PASSWORD

  echo
  echo "Now the admin account for the /_/ dashboard (separate from the app login):"
  read -r -p "Admin email: " ADMIN_EMAIL
  read -r -s -p "Admin password: " ADMIN_PASSWORD
  echo
  sudo -u teamstream "$INSTALL_DIR/backend/pocketbase" superuser create "$ADMIN_EMAIL" "$ADMIN_PASSWORD"
  unset ADMIN_PASSWORD
else
  echo "pb_data already has data — skipping migrate/seed/admin (already set up)"
fi

echo
echo "== 5/6 — systemd service =="
sudo cp "$INSTALL_DIR/deploy/pocketbase.service" /etc/systemd/system/pocketbase.service
sudo systemctl daemon-reload
sudo systemctl enable --now pocketbase
sleep 1
sudo systemctl status pocketbase --no-pager || true
echo "-- API check (expect 3 members) --"
curl -s http://127.0.0.1:8090/api/collections/members/records | head

echo
echo "== 6/6 — Cloudflare Tunnel =="
if ! command -v cloudflared &>/dev/null; then
  TMP=$(mktemp -d)
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o "$TMP/cloudflared.deb"
  sudo dpkg -i "$TMP/cloudflared.deb"
  rm -rf "$TMP"
fi

sudo mkdir -p /root/.cloudflared

if [ ! -f /root/.cloudflared/cert.pem ]; then
  echo "A login URL will print below — open it on any device and authorize the domain."
  sudo cloudflared tunnel login
fi

if ! sudo cloudflared tunnel list 2>/dev/null | grep -qw teamstream; then
  sudo cloudflared tunnel create teamstream
fi

TUNNEL_ID=$(sudo find /root/.cloudflared -maxdepth 1 -name '*.json' -exec basename {} .json \; | head -1)
echo "Tunnel ID: $TUNNEL_ID"

sudo cloudflared tunnel route dns teamstream teamstream.shayaandanishansari.com || echo "(route may already exist — continuing)"

sudo mkdir -p /root/.cloudflared
sudo cp "$INSTALL_DIR/deploy/cloudflared/config.yml" /root/.cloudflared/config.yml
sudo sed -i "s/<TUNNEL_ID>/$TUNNEL_ID/" /root/.cloudflared/config.yml

sudo cloudflared service install
sudo systemctl restart cloudflared 2>/dev/null || sudo systemctl start cloudflared
sudo systemctl status cloudflared --no-pager || true

echo
echo "== Done =="
echo "Open https://teamstream.shayaandanishansari.com — pick your name, enter the shared password."
echo "Admin dashboard: https://teamstream.shayaandanishansari.com/_/"
