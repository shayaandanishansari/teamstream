# Build the React web app and fold it into PocketBase's static dir.
# Run on the Windows dev machine, then ship backend/ to the Linux box.
# The output is plain static files - platform-independent, so building here and
# copying to Linux is fine. The box has no node toolchain, which is why
# backend/pb_public is tracked in git at all.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$web  = Join-Path $root 'web'
$src  = Join-Path $web  'dist'
$dst  = Join-Path $root 'backend\pb_public'

Push-Location $web
try {
    # `npm ci` rather than `npm install`: it installs exactly what the lockfile
    # says, so a deploy build cannot silently pick up a different dependency
    # tree from the one that was tested.
    npm ci
    if ($LASTEXITCODE -ne 0) { throw "npm ci failed" }

    # The checks that are cheap and would be embarrassing to skip: the palette
    # contrast assertions and the unit tests both run in well under a second,
    # and a deploy is exactly when nobody wants to discover a regression.
    npm run verify
    if ($LASTEXITCODE -ne 0) { throw "palette verification failed" }
    npm test
    if ($LASTEXITCODE -ne 0) { throw "tests failed" }

    # Served at the domain root, so Vite's default base "/" is correct.
    npm run build
    if ($LASTEXITCODE -ne 0) { throw "build failed" }
} finally {
    Pop-Location
}

# Remove-then-copy rather than pointing Vite's outDir at pb_public: the same
# shape the Flutter script had, it needs no out-of-root escape flag, and it
# guarantees nothing from the previous build survives. NOTE that this means
# anything else placed in pb_public by hand is destroyed by a rebuild.
if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
Copy-Item -Recurse $src $dst

$size = (Get-ChildItem $dst -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Host "Web build -> $dst  ($([math]::Round($size/1MB,1)) MB)" -ForegroundColor Green
Write-Host "The Flutter build this replaced was 36 MB, of which 32 MB was canvaskit." -ForegroundColor DarkGray
Write-Host "Now: git add backend/pb_public; git commit; git push; then on the box" -ForegroundColor Green
Write-Host "     cd /opt/teamstream && git pull && sudo systemctl restart pocketbase" -ForegroundColor Green
