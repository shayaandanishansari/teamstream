@echo off
REM ── TeamStream: start backend + web app in two windows ──
echo Starting TeamStream (PocketBase + Flutter web)...

start "TeamStream - PocketBase" cmd /k "cd /d C:\Drives\F\Work\TeamStream\backend && pocketbase.exe serve --http=127.0.0.1:8090"

start "TeamStream - App" cmd /k "cd /d C:\Drives\F\Work\TeamStream\app && flutter run -d web-server --web-port=5000 --web-hostname=127.0.0.1"

echo.
echo Two windows opened. Wait for the App window to say "is being served at",
echo then open:  http://127.0.0.1:5000
echo.
pause
