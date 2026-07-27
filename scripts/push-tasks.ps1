<#
.SYNOPSIS
  Push tasks onto the live TeamStream board from the command line.

.DESCRIPTION
  Signs in to the deployed PocketBase with the shared password, finds (or
  creates) a Work by title, and appends tasks to it. Writes go through the
  normal REST API, so the pb_hooks history log records them like any other
  edit, and open apps get them live over realtime. Nothing to do on the box.

  The shared password is read from $env:TEAMSTREAM_PASSWORD, or from the file
  ~\.teamstream\password (outside the repo — never commit it).

.EXAMPLE
  .\scripts\push-tasks.ps1 -Work "Website" -Task "Fix nav","Write copy"

.EXAMPLE
  .\scripts\push-tasks.ps1 -Work "Launch" -Task "Book venue" -Due 2026-08-14 -Critical
#>
[CmdletBinding()]
param(
  # Work (project) to add the tasks under. Matched case-insensitively against
  # non-archived works; created if it doesn't exist.
  [Parameter(Mandatory = $true)][string]$Work,

  # One or more task titles.
  [Parameter(Mandatory = $true)][string[]]$Task,

  # Whose name the history log attributes these writes to.
  [ValidateSet('Shayaan', 'Umair', 'Tawab')][string]$As = 'Shayaan',

  # Optional per-task extras (applied to every task in this call).
  [string]$Note,
  [string]$Due,
  [switch]$Critical,

  # By default a task whose title already exists in the Work is skipped.
  [switch]$AllowDuplicates,

  # Show what would happen without writing anything.
  [switch]$DryRun,

  [string]$Url = 'https://teamstream.shayaandanishansari.com'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Url = $Url.TrimEnd('/')

# --- shared password -------------------------------------------------------
$password = $env:TEAMSTREAM_PASSWORD
if ([string]::IsNullOrWhiteSpace($password)) {
  $pwFile = Join-Path $HOME '.teamstream\password'
  if (Test-Path $pwFile) { $password = (Get-Content $pwFile -Raw).Trim() }
}
if ([string]::IsNullOrWhiteSpace($password)) {
  throw @"
No shared password found. Set one of these (both stay out of the repo):
  `$env:TEAMSTREAM_PASSWORD = 'the-shared-password'      # this session only
  New-Item -ItemType Directory -Force ~\.teamstream | Out-Null
  Set-Content ~\.teamstream\password 'the-shared-password' -Encoding utf8   # persistent
"@
}

# --- due date --------------------------------------------------------------
$dueIso = $null
if ($PSBoundParameters.ContainsKey('Due') -and -not [string]::IsNullOrWhiteSpace($Due)) {
  try { $dueDt = [datetime]::Parse($Due, [Globalization.CultureInfo]::InvariantCulture) }
  catch { throw "Could not read -Due '$Due'. Use a date like 2026-08-14." }
  # Same shape the app writes: DateTime.toUtc().toIso8601String()
  $dueIso = $dueDt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
}

# --- sign in ---------------------------------------------------------------
$identity = "$($As.ToLower())@teamstream.local"
try {
  $auth = Invoke-RestMethod -Method Post -Uri "$Url/api/collections/members/auth-with-password" `
    -ContentType 'application/json' `
    -Body (@{ identity = $identity; password = $password } | ConvertTo-Json)
} catch {
  throw "Sign-in as $As failed: $($_.Exception.Message). Check the shared password."
}

$headers = @{
  Authorization  = $auth.token
  'X-Actor-Id'   = $auth.record.id
  'X-Actor-Name' = $auth.record.name
}
Write-Host "Signed in as $($auth.record.name) -> $Url" -ForegroundColor DarkGray

# --- find or create the Work ----------------------------------------------
$works = (Invoke-RestMethod -Method Get -Headers $headers `
    -Uri "$Url/api/collections/works/records?perPage=200").items
$target = $works | Where-Object { $_.title -eq $Work -and -not $_.archived } | Select-Object -First 1

if ($null -eq $target) {
  if ($DryRun) {
    Write-Host "would CREATE work '$Work'" -ForegroundColor Yellow
    $target = [pscustomobject]@{ id = '<new>'; title = $Work }
  } else {
    $target = Invoke-RestMethod -Method Post -Headers $headers `
      -Uri "$Url/api/collections/works/records" -ContentType 'application/json' `
      -Body (@{
        title    = $Work
        position = [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()  # app's own convention
        archived = $false
      } | ConvertTo-Json)
    Write-Host "created work '$($target.title)'" -ForegroundColor Green
  }
} else {
  Write-Host "work '$($target.title)' found" -ForegroundColor DarkGray
}

# --- existing task titles (for duplicate skipping) -------------------------
$existing = @()
if ($target.id -ne '<new>') {
  $existing = (Invoke-RestMethod -Method Get -Headers $headers `
      -Uri "$Url/api/collections/tasks/records?perPage=500&filter=$([uri]::EscapeDataString("work='$($target.id)'"))").items |
    Where-Object { -not $_.is_archived } | ForEach-Object { $_.title }
}

# --- create the tasks ------------------------------------------------------
$added = 0; $skipped = 0
foreach ($title in $Task) {
  $title = $title.Trim()
  if ([string]::IsNullOrWhiteSpace($title)) { continue }

  if (-not $AllowDuplicates -and ($existing -contains $title)) {
    Write-Host "  skip (already on the board): $title" -ForegroundColor Yellow
    $skipped++
    continue
  }

  $body = @{
    work     = $target.id
    title    = $title
    position = [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    critical = [bool]$Critical
  }
  if ($Note)    { $body.note = $Note }
  if ($dueIso)  { $body.due_date = $dueIso }

  if ($DryRun) {
    Write-Host "  would add: $title" -ForegroundColor Yellow
  } else {
    Invoke-RestMethod -Method Post -Headers $headers -Uri "$Url/api/collections/tasks/records" `
      -ContentType 'application/json' -Body ($body | ConvertTo-Json) | Out-Null
    Write-Host "  added: $title" -ForegroundColor Green
    $existing += $title
  }
  $added++
}

$verb = if ($DryRun) { 'would add' } else { 'added' }
Write-Host "$verb $added task(s) to '$Work'$(if ($skipped) { ", skipped $skipped duplicate(s)" })." -ForegroundColor Cyan
