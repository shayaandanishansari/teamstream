# Build the Flutter web app and fold it into PocketBase's static dir.
# Run on the Windows dev machine, then ship backend/ to the Linux box.
# The output is plain static files (HTML/JS/wasm) — platform-independent, so
# building here and copying to Linux is fine.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$app  = Join-Path $root 'app'
$src  = Join-Path $app  'build\web'
$dst  = Join-Path $root 'backend\pb_public'

Push-Location $app
try {
    # Served at the domain root, so default base href "/" is correct.
    flutter build web --release
} finally {
    Pop-Location
}

if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
Copy-Item -Recurse $src $dst

Write-Host "Web build -> $dst" -ForegroundColor Green
Write-Host "Now copy backend/ (pb_public, pb_migrations, pb_hooks) to the Linux box." -ForegroundColor Green
