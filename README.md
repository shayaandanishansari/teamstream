# TeamStream

A minimal shared task + time tracker built for one specific team: three
people, one board, no accounts to manage. Tap your name, enter the one shared
password, and you're in — add tasks, start a timer on one, and the whole team
sees it live.

Not a product for the general public — it's a personal tool, open-sourced as
one. See [Origin & credits](#origin--credits) for why it's public at all.

## What it does

- **Works → Tasks → timers.** A Work is a project; it holds Tasks; a Task has
  a start/stop timer. Only one thing runs at a time per person.
- **Realtime, no refresh.** Every device sees every edit the moment it
  happens — PocketBase's SSE realtime, not polling.
- **History, not audit logs.** Every create/update/delete on the data
  collections is captured with a full before/after snapshot
  (`backend/pb_hooks/history.pb.js`), so anything can be traced back or
  revived.
- **Runaway timers close themselves.** A timer nobody stopped caps at 3 hours
  even if every browser involved is closed
  (`backend/pb_hooks/close_runaway_timers.pb.js`).
- **A shared drive**, not just task attachments: chunked, resumable uploads
  for files far larger than a form field should carry (see [`files/`](./files)).
- **Identity without accounts.** There's no signup. Three named members share
  one password; who did what comes from who tapped the task, sent as a header
  on every write.

## Architecture

```
phone/laptop ──https──► Cloudflare Tunnel ──► box (single Linux host)
                                                ├─ PocketBase :8090 ─ auth, data, realtime
                                                │                     serves the built React app
                                                └─ FastAPI    :8091 ─ file bytes only (/files/*)
```

One box, two local-only services, one ingress. **PocketBase** is the
sovereign backend — auth, the task/timer data model, realtime, and the built
frontend all come from a single binary. **FastAPI** exists solely because
PocketBase's file field is one uncapped multipart request with no chunking or
resume, and Cloudflare caps any single request body at 100MB regardless of
what serves it — so large files (video, multi-GB folders) get their own
chunked-upload service that never holds more privilege than the member
uploading. Full write-up, including why each piece is shaped the way it is:
[`deploy/DEPLOY.md`](./deploy/DEPLOY.md).

## Repo layout

```
backend/            PocketBase: migrations (schema), pb_hooks (server logic),
                     pb_public (built frontend — see scripts/build-web.ps1)
web/                 The frontend: React + TypeScript + Vite
files/               The file service: FastAPI, chunked upload, thumbnails
app/                 Legacy: the original Flutter frontend, superseded by
                     web/ (kept for history — see plan.md for why it was dropped)
deploy/              systemd units, the Cloudflare Tunnel config, and
                     DEPLOY.md — the full deploy story end to end
scripts/             build-web.ps1 (build + fold into pb_public),
                     push-tasks.ps1 (script tasks onto the live board)
```

## Running it locally

Needs the PocketBase binary (not committed — see `deploy/DEPLOY.md` for the
version), Python 3.11+, and Node.

```bat
run.bat
```

Opens three windows: PocketBase against a throwaway dev database
(`backend/pb_data_dev`, built fresh from `backend/pb_migrations`), the file
service on `:8091`, and Vite on `:5173`. Vite proxies `/api` and `/files` to
the other two, so dev is same-origin exactly like production — the one place
that has to match, since the file service's session cookie is origin-scoped.

Sign in as any of the three seeded names with the local dev password printed
by `run.bat`. The real shared password used on the live deployment is never
in the dev database.

## Deploying

[`deploy/DEPLOY.md`](./deploy/DEPLOY.md) is the whole path: building the
frontend, cloning onto the box, migrating PocketBase, wiring the Cloudflare
Tunnel, standing up the file service, and redeploying after a code change. It
also documents the gotchas that actually happened — like the timer-cap sweep
bug where an ISO date cutoff sorted below a space-separated one and silently
closed every live timer for a day.

## Security model

Access is gated by **one shared password** — deliberately, for a household
team where per-person accounts would be theatre. Every data collection
requires a signed-in request, so the URL alone grants nothing. The one
intentional exception: attachment file bytes are served unauthenticated at
unguessable URLs, because a protected `<img src>` breaks the instant its token
expires. Treat a pasted file link like a pasted file. Full reasoning in
[`deploy/DEPLOY.md`](./deploy/DEPLOY.md#notes--gotchas).

If you fork this for your own team: rotate the shared password immediately
(the admin dashboard, not a migration re-run), and don't reuse the domain or
tunnel config in this repo — they're wired to the author's own deployment.

## Origin & credits

Built by **Shayaan Danish Ansari** — co-founder of [**Stu**](https://stu-concierge.com),
an agentic e-commerce platform (landing page:
[home.stu-concierge.com](https://home.stu-concierge.com)) — to replace a
group chat and a spreadsheet with something his own team could actually see
the state of. Open-sourced as a working example of a self-hosted,
sovereign-backend tool: one binary for auth + data + realtime, no third-party
SaaS in the data path beyond the tunnel that terminates TLS.

- Website: [shayaandanishansari.com](https://shayaandanishansari.com)
- Email: [shayaan0303@gmail.com](mailto:shayaan0303@gmail.com)
- GitHub: [github.com/shayaandanishansari](https://github.com/shayaandanishansari)
- LinkedIn: [linkedin.com/in/shayaan-danish-ansari-43a852246](https://www.linkedin.com/in/shayaan-danish-ansari-43a852246/)

## License

[AGPL-3.0](./LICENSE) © 2026 Shayaan Danish Ansari
