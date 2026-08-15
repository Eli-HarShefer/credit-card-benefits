# Weekly refresh: re-harvest the public catalogues and rebuild the dashboard.
# Registered as a Windows scheduled task by scripts\install-schedule.ps1.
#
# Covers only the sources that need no login:
#   be-plus.co.il  (Behatsdaa "hanachot plus" - automatic discount at charge)
#   max.co.il      (TAU + Behatsdaa benefits)
#
# NOT covered - these need a logged-in browser and a Claude session:
#   behatsdaa.org.il club catalogue  (OTP login, and it rate-limits hard)
#   benefits.isracard.co.il          (CDN blocks non-browser clients)
#
# ASCII-only source (PowerShell 5.1 reads .ps1 as ANSI).

$ErrorActionPreference = 'Continue'
# Child-process stdout arrives as OEM codepage otherwise, which mangles Hebrew in the log.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path -Parent $PSScriptRoot
$log  = Join-Path $root 'data\refresh.log'

function Say($msg){
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $msg
  Write-Host $line
  Add-Content -Path $log -Value $line -Encoding UTF8
}

Say '--- refresh start ---'

# scrub-personal runs before the push, every time - the repo is public.
foreach ($s in @('harvest-beplus.ps1','harvest-max.ps1','harvest-payback.ps1',
                 'scrub-personal.ps1','build-dashboard.ps1')) {
  $path = Join-Path $PSScriptRoot $s
  Say "running $s"
  try {
    & powershell -ExecutionPolicy Bypass -File $path *>&1 | ForEach-Object { Say "  $_" }
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { Say "  WARN exit=$LASTEXITCODE" }
  } catch {
    Say "  FAILED $($_.Exception.Message)"
  }
}

# Push the rebuilt site so the phone picks it up on its own. This is the whole point
# of hosting it on a real origin: no session with Claude needed to publish content.
Push-Location $root
try {
  $changed = git status --porcelain 2>&1
  if ($changed) {
    git add -A 2>&1 | Out-Null
    git commit -m "weekly refresh $(Get-Date -Format 'yyyy-MM-dd')" 2>&1 | Out-Null
    $push = git push 2>&1 | Out-String
    Say "pushed: $($push.Trim())"
  } else {
    Say 'nothing changed, nothing pushed'
  }
} catch {
  Say "git push failed: $($_.Exception.Message)"
} finally {
  Pop-Location
}

Say '--- refresh done ---'
