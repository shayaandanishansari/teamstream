@echo off
REM ── TeamStream: start backend + web app in two windows ──
echo Starting TeamStream (PocketBase + Flutter web)...

start "TeamStream - PocketBase" cmd /k "cd /d C:\Drives\F\Work\TeamStream\backend && pocketbase.exe serve --http=127.0.0.1:8090"

REM PB_URL is required here: the dev server and PocketBase are on different
REM ports, so the same-origin default in app/lib/config.dart would aim the API
REM at the dev server (:5000) and every call would come back as index.html.
start "TeamStream - App" cmd /k "cd /d C:\Drives\F\Work\TeamStream\app && flutter run -d web-server --web-port=5000 --web-hostname=127.0.0.1 --dart-define=PB_URL=http://127.0.0.1:8090"

echo.
echo Two windows opened. Wait for the App window to say "is being served at",
echo then open:  http://127.0.0.1:5000
echo.
pause
