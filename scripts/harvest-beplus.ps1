# Be-Plus harvester - "hanachot be-maamad ha-chiyuv" (automatic discount at charge time)
# Club: Behatsdaa. Site is PUBLIC (no login needed).
# Data lives as JSON inside the data attribute of the <products> element.
#
# Weekly refresh:
#   powershell -ExecutionPolicy Bypass -File scripts\harvest-beplus.ps1
#
# NOTE: keep this file ASCII-only. PowerShell 5.1 reads .ps1 as ANSI, so Hebrew
# literals in source get mangled. All Hebrew comes from the site at runtime.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'data'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

$BASE = 'https://be-plus.co.il/component/crm/products'

function Get-Page {
  param([int]$CatId, [int]$Limit)
  return (Invoke-WebRequest -Uri "$BASE`?cat_id=$CatId&limit=$Limit" -UseBasicParsing -TimeoutSec 180).Content
}

# ---- 1. taxonomy (categories + geos) --------------------------------------
Write-Host 'Fetching taxonomy...'
$seed = Get-Page -CatId 78 -Limit 10
$fm = [regex]::Match($seed, '<filterprods[^>]*data="(.+?)"\s*>', 'Singleline')
if (-not $fm.Success) { throw 'taxonomy element not found' }
$tax = [System.Net.WebUtility]::HtmlDecode($fm.Groups[1].Value) | ConvertFrom-Json

$catName = @{}
foreach ($c in $tax.cats) { $catName[[string]$c.id] = $c.cat_name }
$tops = $tax.cats | Where-Object { $_.parent_id -eq 0 }
Write-Host "  categories: $($tax.cats.Count)  (top-level: $($tops.Count))   geos: $($tax.geos.Count)"

# ---- 2. harvest every top-level category ----------------------------------
$all = [System.Collections.Generic.List[object]]::new()
$summary = [System.Collections.Generic.List[object]]::new()

foreach ($c in $tops) {
  Write-Host ("  [{0,5}] {1,-42} " -f $c.id, $c.cat_name) -NoNewline
  try {
    $html = Get-Page -CatId $c.id -Limit 4000
    $m = [regex]::Match($html, "<products\s+ref=""products""\s+main=""true""\s+data='(.+?)'\s*>", 'Singleline')
    $recs = if ($m.Success) { $m.Groups[1].Value | ConvertFrom-Json } else { @() }
    foreach ($r in $recs) {
      $subs = @()
      foreach ($cid in ($r.cat_id -split ',')) {
        $cid = $cid.Trim()
        if ($cid -and $catName.ContainsKey($cid)) { $subs += $catName[$cid] }
      }
      $all.Add([pscustomobject]@{
        id           = $r.id
        name         = $r.model
        discount_pct = [double]$r.price
        city         = $r.city
        address      = $r.address
        note         = $r.free_text
        category     = $c.cat_name
        cat_id       = $c.id
        all_categories = ($subs | Select-Object -Unique)
        url          = "https://be-plus.co.il/product/$($r.id)"
      })
    }
    $summary.Add([pscustomobject]@{ id = $c.id; category = $c.cat_name; count = $recs.Count })
    Write-Host $recs.Count
  } catch {
    Write-Host "FAILED - $($_.Exception.Message)"
    $summary.Add([pscustomobject]@{ id = $c.id; category = $c.cat_name; count = 0 })
  }
  Start-Sleep -Milliseconds 500
}

# ---- 3. dedupe by merchant id ---------------------------------------------
$unique = $all | Group-Object id | ForEach-Object {
  $g = $_.Group
  $cats = $g | ForEach-Object { $_.category } | Select-Object -Unique
  $o = $g[0]
  [pscustomobject]@{
    id           = $o.id
    name         = $o.name
    discount_pct = $o.discount_pct
    city         = $o.city
    address      = $o.address
    note         = $o.note
    categories   = $cats
    all_categories = $o.all_categories
    url          = $o.url
  }
}

$payload = [pscustomobject]@{
  source           = 'be-plus.co.il'
  club             = 'behatsdaa'
  card             = 'behatsdaa'
  mechanic         = 'auto'
  mechanic_note    = 'Automatic discount applied at charge time. No activation, no coupon - just pay with the card.'
  harvested_at     = (Get-Date -Format 'yyyy-MM-dd')
  rows             = $all.Count
  unique_merchants = ($unique | Measure-Object).Count
  categories       = $summary
  merchants        = $unique
}

$outFile = Join-Path $outDir 'be-plus.json'
$payload | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding utf8

Write-Host ''
Write-Host '--------------------------------------------'
Write-Host "rows:   $($all.Count)"
Write-Host "unique: $(($unique | Measure-Object).Count)"
Write-Host "out:    $outFile"
