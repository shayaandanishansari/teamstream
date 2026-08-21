@echo off
REM -- TeamStream dev: PocketBase, the file service, and Vite, in three windows.
echo Starting TeamStream (PocketBase + files + web)...

REM --dir points at pb_data_dev, a throwaway database built fresh from
REM pb_migrations. The tracked pb_data on this machine drifted from the
REM migrations at some point (members ended up a base collection, so
REM auth-with-password 404s), and rather than repair live data we build a
REM correct one. Recreate it with:
REM   cd backend
REM   set TEAMSTREAM_PASSWORD=teamstream-dev-local
REM   pocketbase.exe migrate up --dir=%CD%\pb_data_dev --migrationsDir=%CD%\pb_migrations
start "TeamStream - PocketBase" cmd /k "cd /d C:\Drives\F\Work\TeamStream\backend && pocketbase.exe serve --http=127.0.0.1:8090 --dir=C:\Drives\F\Work\TeamStream\backend\pb_data_dev --hooksDir=C:\Drives\F\Work\TeamStream\backend\pb_hooks"

REM Note there is no space before each && -- a trailing space becomes part of
REM the environment variable's value.
start "TeamStream - Files" cmd /k "cd /d C:\Drives\F\Work\TeamStream\files && set TS_FILES_ROOT=C:\Drives\F\Work\TeamStream\.filestore&& set TS_PB_URL=http://127.0.0.1:8090&& set TS_COOKIE_SECURE=0&& python -m uvicorn app.main:app --host 127.0.0.1 --port 8091 --reload"

REM No PB_URL to define any more. Vite proxies /api to :8090 and /files to
REM :8091, so dev is same-origin exactly as production is -- which is also the
REM only way the ts_files cookie behaves the same in both.
start "TeamStream - Web" cmd /k "cd /d C:\Drives\F\Work\TeamStream\web && npm run dev"

echo.
echo Three windows opened. Wait for the Web window to say "ready", then open:
echo    http://localhost:5173
echo.
echo Sign in as any of the three names with the LOCAL dev password:
echo    teamstream-dev-local
echo (The real shared password is not in the dev database, on purpose.)
echo.
pause
