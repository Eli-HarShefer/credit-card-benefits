# Geocodes Be-Plus merchant addresses so the app can sort by real distance.
#   powershell -ExecutionPolicy Bypass -File scripts\geocode.ps1
#
# Why this runs at BUILD time: a published Artifact is under a strict CSP and cannot
# call any external host, so coordinates must already be in the payload.
#
# Nominatim's usage policy allows ~1 request/second from a single identified client,
# so this is deliberately slow. It is fully resumable - every lookup is cached in
# data\geocache.json and skipped on the next run. Kill it and restart any time.
#
# Tier-1 categories (meat, groceries, restaurants, car, home, health...) are done
# first, so the useful half lands long before the long tail finishes.
#
# ASCII-ONLY source (PowerShell 5.1 reads .ps1 as ANSI).

param([int]$Max = 100000)

$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root  = Split-Path -Parent $PSScriptRoot
$data  = Join-Path $root 'data'
$cacheFile = Join-Path $data 'geocache.json'
$UA = 'CreditCardBenefitsMap/1.0 (personal use)'

# ---- load cache ----------------------------------------------------------
$cache = @{}
if (Test-Path $cacheFile) {
  $raw = Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($p in $raw.PSObject.Properties) { $cache[$p.Name] = $p.Value }
}
Write-Host "cache: $($cache.Count) entries"

# ---- build the work list, priority first ---------------------------------
$G  = Get-Content (Join-Path $data 'groups.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$bp = Get-Content (Join-Path $data 'be-plus.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$tier1 = @{}
foreach ($grp in $G.groups) {
  if ($grp.tier -eq 1) { foreach ($c in $grp.cats) { $tier1[$c.Trim()] = $true } }
}

# Wallet branch addresses arrive as one glued string ("שד בן גוריון 84 קרית מוצקין"),
# which Nominatim handles fine as free text.
$walletWork = @()
$brFile = Join-Path $data 'behatsdaa-branches.json'
if (Test-Path $brFile) {
  $bj = Get-Content $brFile -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($p in $bj.branches.PSObject.Properties) {
    foreach ($b in $p.Value) {
      if ($b.a) { $walletWork += [pscustomobject]@{ q = ([string]$b.a).Trim(); prio = 0 } }
    }
  }
}

$work = foreach ($m in $bp.merchants) {
  $addr = [string]$m.address
  $city = [string]$m.city
  if ([string]::IsNullOrWhiteSpace($addr) -or $addr -match '^\s*0\s*$') { continue }
  if ([string]::IsNullOrWhiteSpace($city) -or $city -eq 'online' -or $city -match '^CITY\d*$') { continue }

  $isTop = $false
  foreach ($c in @($m.all_categories)) {
    if ($c -and $tier1.ContainsKey(($c -replace '^\s*-\s*', '').Trim())) { $isTop = $true; break }
  }
  [pscustomobject]@{ q = "$addr, $city"; prio = $(if ($isTop) { 0 } else { 1 }) }
}

$queue = @($walletWork) + @($work) | Group-Object q | ForEach-Object { $_.Group[0] } |
         Sort-Object prio | Where-Object { -not $cache.ContainsKey($_.q) }

Write-Host "to geocode: $(($queue | Measure-Object).Count)  (tier-1 first)"

# ---- geocode -------------------------------------------------------------
$done = 0; $hit = 0; $miss = 0
foreach ($item in $queue) {
  if ($done -ge $Max) { break }
  $url = 'https://nominatim.openstreetmap.org/search?format=json&limit=1&countrycodes=il&q=' +
         [uri]::EscapeDataString($item.q)
  try {
    $r = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = $UA } -TimeoutSec 30
    if ($r -and $r.Count -gt 0) {
      $cache[$item.q] = @([math]::Round([double]$r[0].lat, 5), [math]::Round([double]$r[0].lon, 5))
      $hit++
    } else {
      $cache[$item.q] = $null   # remember the miss so we don't ask again
      $miss++
    }
  } catch {
    Start-Sleep -Seconds 5      # back off, leave it uncached to retry next run
  }
  $done++

  if ($done % 50 -eq 0) {
    $cache | ConvertTo-Json -Depth 4 -Compress | Out-File $cacheFile -Encoding utf8
    Write-Host ("  {0,6} done   hit {1}  miss {2}" -f $done, $hit, $miss)
  }
  Start-Sleep -Milliseconds 1100
}

$cache | ConvertTo-Json -Depth 4 -Compress | Out-File $cacheFile -Encoding utf8
Write-Host ''
Write-Host "done this run: $done   hit: $hit   miss: $miss"
Write-Host "cache total:   $($cache.Count)"
Write-Host "out: $cacheFile"
