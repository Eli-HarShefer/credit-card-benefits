# Builds dashboard.html from the harvested data files.
#   powershell -ExecutionPolicy Bypass -File scripts\build-dashboard.ps1
#
# Shape is driven by how the thing is actually used: you are standing somewhere,
# you forgot what you have, so you pick a category and then your city.
# Category -> place -> answer. No typing required.
#
# ASCII-ONLY source. PowerShell 5.1 reads .ps1 as ANSI and mangles Hebrew literals,
# so every Hebrew string lives in data\strings.json and is read as UTF8.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$data = Join-Path $root 'data'

$S = Get-Content (Join-Path $data 'strings.json') -Raw -Encoding UTF8 | ConvertFrom-Json

# Official city list from the Behatsdaa API - used to split "street + city" strings
# that come back glued together in wallet branch addresses. Longest first so
# "תל אביב - יפו" wins over any shorter city that is a suffix of it.
$cityCanonNames = @()
$cityFile = Join-Path $data 'behatsdaa-cities.json'
if (Test-Path $cityFile) {
  $cj = Get-Content $cityFile -Raw -Encoding UTF8 | ConvertFrom-Json
  $cityCanonNames = $cj.cities | ForEach-Object { $_.cityName.Trim() } |
                    Where-Object { $_ } | Sort-Object -Property Length -Descending
}

$rows = [System.Collections.Generic.List[object]]::new()

function Add-Row {
  param($name, $offer, $pct, $card, $act, $cats, $city, $addr, $url)
  $rows.Add([pscustomobject]@{
    n = $name; o = $offer; p = $pct; c = $card; a = $act
    k = @($cats); w = $city; d = $addr; u = $url
  })
}

# ---- Be-Plus: automatic discount, carries city + full category tree ------
$bp = Get-Content (Join-Path $data 'be-plus.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($m in $bp.merchants) {
  # child categories arrive prefixed with "- "; strip it, keep the specific name
  $cats = @($m.all_categories) | Where-Object { $_ } | ForEach-Object { ($_ -replace '^\s*-\s*', '').Trim() }
  if (-not $cats) { $cats = @($m.categories) }

  # The source carries junk in the geo column - placeholder codes and a stray
  # "online customer" label. Left alone these become their own fake cities.
  $city = [string]$m.city
  if ($city -eq 'online' -or $city -eq $S.online_customer) { $city = $S.cat_online }
  elseif ([string]::IsNullOrWhiteSpace($city) -or $city -match '^CITY\d*$') { $city = $S.anywhere }

  $addr = [string]$m.address
  if ($addr -match '^\s*0\s*$' -or [string]::IsNullOrWhiteSpace($addr)) { $addr = $null }

  Add-Row $m.name ("$($m.discount_pct)" + $S.discount_suffix) ([double]$m.discount_pct) `
          'behatsdaa' $null $cats $city $addr $m.url
}

# ---- max: TAU + Behatsdaa. No geography - these are country-wide ---------
$maxPath = Join-Path $data 'max.json'
if (Test-Path $maxPath) {
  $mx = Get-Content $maxPath -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($b in $mx.benefits) {
    $offer = [string]$b.offer
    $act = $null
    if ($offer -match $S.match_cashback)  { $act = $S.act_payback }
    elseif ($offer -match $S.match_pinuk) { $act = $S.act_pinuk }
    Add-Row $b.name $offer 0 'tau' $act @($b.categories) $S.anywhere $null $b.url
  }
}

# ---- Behatsdaa digital wallet -------------------------------------------
# The best rates in the whole project by a wide margin (7-20% vs Be-Plus's 2-3%),
# and the only place with real supermarket chains. Different mechanic though:
# you pre-load money onto the wallet at a discount, then pay with it at the till,
# capped per calendar month. A chain can sit in several wallets - keep the best rate.
$walPath = Join-Path $data 'behatsdaa-wallet.json'
if (Test-Path $walPath) {
  $wal = Get-Content $walPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $best = @{}
  $today = (Get-Date).Date
  foreach ($w in $wal.wallets) {
    # a promo wallet ("... until 30/9") drops out by itself once its date has passed
    if ($w.until -and ([datetime]::ParseExact([string]$w.until, 'yyyy-MM-dd', $null) -lt $today)) { continue }
    foreach ($cat in $w.categories) {
      foreach ($ch in $cat.chains) {
        $nm = [string]$ch.name
        if (-not $nm) { continue }
        $k = $nm.Trim()
        if (-not $best.ContainsKey($k) -or $w.pct -gt $best[$k].pct) {
          $best[$k] = [pscustomobject]@{
            pct = [double]$w.pct; cap = $w.cap; wallet = $w.name.Trim()
            tag = $cat.tag; site = $ch.site
          }
        }
      }
    }
  }
  # Branch-level rows where we have them, so a wallet chain shows up under the city
  # it actually has a shop in rather than a vague "nationwide".
  $branches = @{}
  $brFile = Join-Path $data 'behatsdaa-branches.json'
  if (Test-Path $brFile) {
    $bj = Get-Content $brFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $bj.branches.PSObject.Properties) { $branches[$p.Name] = $p.Value }
    Write-Host "wallet branches: $(($branches.Values | ForEach-Object { $_ } | Measure-Object).Count)"
  }
  $chainIdByName = @{}
  if (Test-Path $brFile) {
    $bj2 = Get-Content $brFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($c in $bj2.chains) { $chainIdByName[([string]$c.name).Trim()] = $c.chainId }
  }

  $WALLET_URL = 'https://www.behatsdaa.org.il/card/chargingCard'
  foreach ($k in $best.Keys) {
    $b = $best[$k]
    # Name the exact wallet - there are six, and loading the wrong one buys nothing.
    $wname = ($b.wallet -replace '\s+', ' ').Trim()
    $act = [string]::Format($S.act_wallet, $wname, $b.cap)
    $cid = $chainIdByName[$k]
    $rowsAdded = 0
    if ($cid -and $branches.ContainsKey([string]$cid)) {
      foreach ($br in $branches[[string]$cid]) {
        $addr = [string]$br.a
        if (-not $addr) { continue }
        # "התעש 24 כפר סבא" - the city is the tail; match it against the known list
        $city = $null
        foreach ($cn in $cityCanonNames) {
          if ($addr.EndsWith($cn)) { $city = $cn; break }
        }
        if (-not $city) { continue }
        $street = $addr.Substring(0, $addr.Length - $city.Length).Trim()
        Add-Row $k ("$($b.pct)" + $S.discount_suffix) $b.pct 'wallet' $act `
                @($b.tag) $city $street $WALLET_URL
        $rowsAdded++
      }
    }
    # no branch data (online-only, or not harvested yet) - keep the nationwide row
    if ($rowsAdded -eq 0) {
      Add-Row $k ("$($b.pct)" + $S.discount_suffix) $b.pct 'wallet' $act `
              @($b.tag) $S.anywhere $null $WALLET_URL
    }
  }
}

# ---- max PayBack: online cashback, TAU / Behatsdaa -----------------------
# This is also where the "which card do I pull out" answer gets decided, because
# One Zero offers many of the same shops through TOPCASH at a different rate.
function Norm { param([string]$s) ($s -replace '[^a-zA-Z0-9֐-׿]', '').ToLower() }

$izPath = Join-Path $data 'isracard-online.json'
$izRates = @{}
if (Test-Path $izPath) {
  $izTmp = Get-Content $izPath -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($c in $izTmp.cashback_topcash) {
    $k = Norm $c.merchant
    if ($k) { $izRates[$k] = [double](($c.rate -replace '[^\d\.]', '')) }
  }
}

$pbPath = Join-Path $data 'payback.json'
$pbSeen = @{}
if (Test-Path $pbPath) {
  $pb = Get-Content $pbPath -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($r in $pb.retailers) {
    $k = Norm $r.name
    $pbSeen[$k] = $true
    $act = $S.act_payback_go

    # does One Zero cover the same shop, and does it beat max?
    $rival = $null
    foreach ($ik in $izRates.Keys) {
      if ($k -and ($k -like "*$ik*" -or $ik -like "*$k*")) { $rival = $izRates[$ik]; break }
    }
    if ($null -ne $rival) {
      if ($rival -gt $r.rate_pct) { $act = [string]::Format($S.better_onezero, $rival) }
      elseif ($r.rate_pct -gt $rival) { $act = [string]::Format($S.better_max, $rival) }
    }

    Add-Row $r.name $r.rate_text ([double]$r.rate_pct) 'tau' $act `
            @($S.cat_online) $S.anywhere $null $r.url
  }
}

# ---- isracard / One Zero ------------------------------------------------
$IZURL = 'https://benefits.isracard.co.il/benefitsforall/online/'
if (Test-Path $izPath) {
  $iz = Get-Content $izPath -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($c in $iz.cashback_topcash) {
    # skip shops max already covers at an equal-or-better rate - one row per shop
    $k = Norm $c.merchant
    $dupe = $false
    foreach ($pk in $pbSeen.Keys) { if ($k -and ($k -like "*$pk*" -or $pk -like "*$k*")) { $dupe = $true; break } }
    if ($dupe) { continue }
    Add-Row $c.merchant ($c.rate + $S.cashback_suffix) 0 'onezero' $S.act_topcash `
            @($S.cat_online) $S.anywhere $null $IZURL
  }
  foreach ($v in $iz.vouchers) {
    $label = [string]::Format($S.voucher_fmt, $v.face, $v.price)
    # A voucher for a grocery chain is the only supermarket-chain benefit that exists
    # across all three cards, so it gets filed under that category rather than buried
    # with the fashion vouchers.
    $vcat = if ($v.merchant -match $S.match_superchain) { $S.cat_super_chain } else { $S.cat_voucher }
    Add-Row $v.merchant $label ([double]$v.off_pct) 'onezero' $S.act_voucher `
            @($vcat) $S.anywhere $null $IZURL
  }
  foreach ($o in $iz.other) {
    Add-Row $o.merchant $o.offer 0 'onezero' $null @($S.cat_online) $S.anywhere $null $IZURL
  }
}

# ---- TAU club (tauclub.co.il): the card's own club benefits ----------------
# Mostly country-wide discounts at the till and Gift Card ACADEMIC chains. Its
# max PayBack entries are skipped - payback.json already has them, at the same rates.
# Campus benefits are pinned to the university so they land in the campus district.
$tcPath = Join-Path $data 'tauclub.json'
if (Test-Path $tcPath) {
  $tc = Get-Content $tcPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $tcAdded = 0
  foreach ($b in $tc.benefits) {
    if ([string]$b.name -match 'PayBack') { continue }
    $offer = [string]$b.discount
    $pct = 0
    $pm = [regex]::Match($offer, '(\d+(?:\.\d+)?)\s*%')
    if ($pm.Success) { $pct = [double]$pm.Groups[1].Value }
    $cats = @($b.categories) | Where-Object { $_ } |
            ForEach-Object { (($_ -replace 'VIEW ALL', '') -replace '\s+', ' ').Trim() } | Where-Object { $_ }
    $act = $null
    if ($offer -match 'ACADEMIC') { $act = $S.act_giftcard }
    $city = $S.anywhere; $addr = $null
    foreach ($c in $cats) { if ($c -match $S.match_tau_campus) { $city = $S.tau_city_canon; $addr = $S.tau_campus_addr; break } }
    Add-Row ([string]$b.name) $offer $pct 'tau' $act $cats $city $addr ([string]$b.url)
    $tcAdded++
  }
  Write-Host "tau club: $tcAdded"
}

# ---- group the raw categories, bucket cities into districts, drop dupes ---
$G = Get-Content (Join-Path $data 'groups.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$catToGroup = @{}
foreach ($grp in $G.groups) {
  foreach ($c in $grp.cats) { $catToGroup[$c.Trim()] = $grp.name }
}
$groupMeta = @{}
foreach ($grp in $G.groups) { $groupMeta[$grp.name] = $grp }

$cityToDistrict = @{}
foreach ($d in $G.districts) {
  foreach ($c in $d.cities) { $cityToDistrict[$c.Trim()] = $d.name }
}

# "פתח תקווה" and "פתח תקוה" are the same place; collapse spelling variants
function Norm-City { param([string]$s) ($s -replace '[\s""'']', '') }
$cityCanon = @{}
foreach ($r in $rows) {
  $w = [string]$r.w
  if (-not $w -or $w -eq $S.anywhere) { continue }
  $k = Norm-City $w
  if (-not $cityCanon.ContainsKey($k)) { $cityCanon[$k] = $w }
}

# Coordinates from the geocoder, so rows can be placed near the TAU campus and,
# later, sorted by real distance in the app.
# Keyed with whitespace collapsed, same as scripts\geocode.ps1 - harvests differ in spacing.
function Norm-Addr([string]$s) { return ($s -replace '\s+', ' ').Trim() }
$geo = @{}
$geoFile = Join-Path $data 'geocache.json'
if (Test-Path $geoFile) {
  $gj = Get-Content $geoFile -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($p in $gj.PSObject.Properties) { if ($p.Value) { $geo[(Norm-Addr $p.Name)] = $p.Value } }
  Write-Host "geocoded: $($geo.Count)"
}

function Get-KmFromTau {
  param([double]$lat, [double]$lon)
  # equirectangular is plenty at city scale and avoids trig-heavy haversine per row
  $dLat = ($lat - [double]$S.tau_lat) * 111.0
  $dLon = ($lon - [double]$S.tau_lon) * 111.0 * [math]::Cos([double]$S.tau_lat * [math]::PI / 180)
  return [math]::Sqrt($dLat * $dLat + $dLon * $dLon)
}

$OTHER_D = $S.district_other
foreach ($r in $rows) {
  # canonical city
  if ($r.w -and $r.w -ne $S.anywhere) {
    $r.w = $cityCanon[(Norm-City $r.w)]
  }
  # coordinates, if the geocoder has reached this address yet.
  # Be-Plus rows were geocoded as "street, city"; wallet branches as the raw glued
  # address string, so try both shapes.
  $lat = $null; $lon = $null
  if ($r.d -and $r.w -and $r.w -ne $S.anywhere) {
    foreach ($key in @((Norm-Addr "$($r.d), $($r.w)"), (Norm-Addr "$($r.d) $($r.w)"))) {
      if ($geo.ContainsKey($key)) { $lat = [double]$geo[$key][0]; $lon = [double]$geo[$key][1]; break }
    }
  }
  if ($null -eq $lat -and $r.d -eq $S.tau_campus_addr) { $lat = [double]$S.tau_lat; $lon = [double]$S.tau_lon }
  $r | Add-Member -NotePropertyName 'lat' -NotePropertyValue $lat -Force
  $r | Add-Member -NotePropertyName 'lon' -NotePropertyValue $lon -Force

  # Is it walking distance from campus? Coordinates decide when we have them;
  # otherwise fall back to the Ramat Aviv street names, so this works before the
  # geocoder has finished its run.
  $nearTau = $false
  if ($null -ne $lat) {
    if ((Get-KmFromTau $lat $lon) -le [double]$S.tau_radius_km) { $nearTau = $true }
  } elseif ($r.w -match $S.tau_city -and $r.d -match $S.tau_streets) {
    $nearTau = $true
  }
  $r | Add-Member -NotePropertyName 'tau' -NotePropertyValue $nearTau -Force

  # district
  $r | Add-Member -NotePropertyName 'r' -NotePropertyValue $(
    if ($nearTau) { $S.district_tau }
    elseif (-not $r.w -or $r.w -eq $S.anywhere -or $r.w -eq $S.cat_online) { $S.anywhere }
    elseif ($cityToDistrict.ContainsKey($r.w)) { $cityToDistrict[$r.w] }
    else { $OTHER_D }
  ) -Force
  # groups (strip the "- " child prefix that survives in some sources)
  $gs = @()
  foreach ($k in $r.k) {
    if (-not $k) { continue }
    $clean = ($k -replace '^\s*-\s*', '').Trim()
    if ($catToGroup.ContainsKey($clean)) { $gs += $catToGroup[$clean] }
    elseif ($catToGroup.ContainsKey($k.Trim())) { $gs += $catToGroup[$k.Trim()] }
  }
  $gs = $gs | Select-Object -Unique
  if (-not $gs) { $gs = @($S.group_misc) }
  $r | Add-Member -NotePropertyName 'gr' -NotePropertyValue @($gs) -Force
}

# one row per merchant+city+card - the same shop reached two ways is still one shop
$rows = $rows | Group-Object { "$($_.n)|$($_.w)|$($_.c)" } | ForEach-Object { $_.Group[0] }

$sorted = $rows | Sort-Object -Property p -Descending

# Live AliExpress promos sit on the PayBack retailer page and rotate weekly.
$aliDeals = @()
try {
  $UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36'
  $ah = (Invoke-WebRequest -Uri 'https://www.pay-back.co.il/retailer/aliexpress' `
          -Headers @{ 'User-Agent' = $UA } -UseBasicParsing -TimeoutSec 60).Content
  # NB: these are PayBack's weekly promos across many shops (urbanica, panda, ...),
  # NOT AliExpress-specific ones. The whole line lives in the anchor's title attr.
  foreach ($m in [regex]::Matches($ah, "promo-item.*?title=""([^""]{6,160})""", 'Singleline')) {
    $t = ([System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)) -replace '\s+', ' '
    $aliDeals += [pscustomobject]@{ t = $t.Trim(); s = '' }
  }
  $aliDeals = $aliDeals | Group-Object t | ForEach-Object { $_.Group[0] } | Select-Object -First 8
} catch { }

$groupsOut = foreach ($grp in $G.groups) {
  $n = ($sorted | Where-Object { $_.gr -contains $grp.name } | Measure-Object).Count
  if ($n -gt 0) {
    [pscustomobject]@{ name = $grp.name; icon = $grp.icon; tier = $grp.tier; n = $n; note = $grp.note }
  }
}
$districtsOut = @(
  [pscustomobject]@{ name = $S.district_tau; icon = $S.district_tau_icon }
) + @(foreach ($d in $G.districts) { [pscustomobject]@{ name = $d.name; icon = $d.icon } })

$payload = [pscustomobject]@{
  built     = (Get-Date -Format 'yyyy-MM-dd')
  rows      = $sorted
  groups    = @($groupsOut)
  districts = @($districtsOut)
  aliDeals  = $aliDeals
}
$json = $payload | ConvertTo-Json -Depth 4 -Compress

# The "my cards" panel is hand-written content, kept in its own file so it can be
# edited without touching code. Parsed first, so a typo fails the build and not the page.
$cardsFile = Join-Path $data 'my-cards.json'
$cardsJson = 'null'
if (Test-Path $cardsFile) {
  $cardsJson = (Get-Content $cardsFile -Raw -Encoding UTF8 | ConvertFrom-Json) | ConvertTo-Json -Depth 8 -Compress
}

$tpl  = Get-Content (Join-Path $root 'template.html') -Raw -Encoding UTF8
$html = $tpl.Replace('/*__DATA__*/', $json).Replace('/*__CARDS__*/', $cardsJson)
$out  = Join-Path $root 'dashboard.html'
[System.IO.File]::WriteAllText($out, $html, (New-Object System.Text.UTF8Encoding($false)))

# docs/ is what GitHub Pages serves (it only accepts / or /docs as the source path).
# The hosted copy also gets the PWA hooks; the Artifact copy stays a plain page
# because its CSP blocks both the manifest fetch and service-worker registration.
$pub = Join-Path $root 'docs'
if (-not (Test-Path $pub)) { New-Item -ItemType Directory -Path $pub | Out-Null }

# Leaflet is no longer in the head: the page fetches it on demand (loadLeaflet in
# template.html), so the first screen never waits on a CDN. The preconnects just
# warm up the two hosts a map will need. In the Artifact copy the CSP blocks the
# fetch and the page simply shows no map.
# The doctype, charset and viewport were missing, so the hosted page ran in
# quirks mode and phones laid it out 980px wide and shrank it. The Artifact copy
# never showed this because its host wraps the page in a proper skeleton.
$pwaHead = @'
<!doctype html>
<html lang="he" dir="rtl">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<link rel="manifest" href="manifest.webmanifest">
<meta name="theme-color" content="#0f6b5f">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<meta name="apple-mobile-web-app-title" content="Benefits">
<link rel="apple-touch-icon" href="icon-192.png">
<link rel="preconnect" href="https://unpkg.com" crossorigin>
<link rel="preconnect" href="https://tile.openstreetmap.org">
'@
$pwaTail = @'
<script>
if ("serviceWorker" in navigator) {
  addEventListener("load", () => navigator.serviceWorker.register("sw.js").catch(() => {}));
}
</script>
'@
$hosted = $pwaHead + $html + $pwaTail
[System.IO.File]::WriteAllText((Join-Path $pub 'index.html'), $hosted, (New-Object System.Text.UTF8Encoding($false)))

$cats = $sorted | ForEach-Object { $_.k } | Where-Object { $_ } | Select-Object -Unique
$cities = $sorted | ForEach-Object { $_.w } | Where-Object { $_ } | Select-Object -Unique
Write-Host "rows:       $(($sorted|Measure-Object).Count)"
Write-Host "categories: $(($cats|Measure-Object).Count)"
Write-Host "cities:     $(($cities|Measure-Object).Count)"
Write-Host "out: $out  ($([math]::Round((Get-Item $out).Length/1MB,2)) MB)"
