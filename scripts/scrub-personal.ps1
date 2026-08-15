# Strips personal financial data from the harvested wallet files before anything
# leaves this machine. The repo is public, so this runs before every push.
#
#   powershell -ExecutionPolicy Bypass -File scripts\scrub-personal.ps1
#
# What goes: current wallet balances and remaining-to-load amounts. Those are
# account state, not catalogue data, and the app never reads them.
# What stays: wallet name, discount rate, monthly cap, chains and branches.
#
# ASCII-ONLY source (PowerShell 5.1 reads .ps1 as ANSI).

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$data = Join-Path $root 'data'

$changed = 0

foreach ($name in @('behatsdaa-wallet.json', 'behatsdaa-branches.json')) {
  $path = Join-Path $data $name
  if (-not (Test-Path $path)) { continue }

  $j = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
  $hit = $false

  if ($j.PSObject.Properties.Name -contains 'wallets') {
    foreach ($w in $j.wallets) {
      foreach ($prop in @('bal', 'left', 'walletBalance', 'maxAmountToLoad', 'loadedThisMonth')) {
        if ($w.PSObject.Properties.Name -contains $prop) {
          $w.PSObject.Properties.Remove($prop); $hit = $true
        }
      }
    }
  }

  if ($hit) {
    $j | ConvertTo-Json -Depth 8 -Compress | Out-File $path -Encoding utf8
    Write-Host "scrubbed: $name"
    $changed++
  } else {
    Write-Host "clean:    $name"
  }
}

# ---- verify nothing personal is left in tracked files --------------------
Push-Location $root
$suspect = @()
foreach ($f in (git ls-files)) {
  if (-not (Test-Path $f)) { continue }
  $c = Get-Content $f -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  if (-not $c) { continue }
  if ($c -match '"(bal|left|walletBalance|cardNumber)"\s*:') { $suspect += "$f (balance/card field)" }
  if ($c -match '\b\d{4}-\d{4}-\d{4}-\d{4}\b')               { $suspect += "$f (card number)" }
}
Pop-Location

Write-Host ''
if ($suspect) {
  Write-Host 'STILL PRESENT:' -ForegroundColor Red
  $suspect | ForEach-Object { Write-Host "  $_" }
  exit 1
} else {
  Write-Host 'no balances or card numbers in tracked files'
}
