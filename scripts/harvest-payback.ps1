# max PayBack harvester - online cashback for the TAU / Behatsdaa cards.
#   powershell -ExecutionPolicy Bypass -File scripts\harvest-payback.ps1
#
# pay-back.co.il is PUBLIC. /category/all renders every retailer server-side inside
# div.retailer_preview blocks, so one request covers the whole catalogue.
#
# Terms that matter and are NOT visible on the retailer pages (they come from the
# signup email) are recorded in the payload so the dashboard can show them:
#   - max CREDIT cards only. NOT cash-card, NOT debit, NOT free, NOT rechesh.
#   - Cashback excludes VAT, taxes, fees, shipping, gift wrap, discounts and credits.
#   - No stacking of promotions unless explicitly stated.
#   - Installments: computed on the full transaction amount, not per instalment.
#
# ASCII-ONLY source (PowerShell 5.1 reads .ps1 as ANSI).

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'data'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36'

Write-Host 'Fetching pay-back catalogue...'
$html = (Invoke-WebRequest -Uri 'https://www.pay-back.co.il/category/all' `
          -Headers @{ 'User-Agent' = $UA } -UseBasicParsing -TimeoutSec 120).Content

# each retailer sits in <div class="... retailer_preview" data-aff='slug'> ... </div>
$blocks = [regex]::Matches($html, "data-aff='([^']+)'(.{0,1400}?)</div>\s*</div>\s*</div>", 'Singleline')
Write-Host "  blocks: $($blocks.Count)"

$list = [System.Collections.Generic.List[object]]::new()
foreach ($b in $blocks) {
  $slug = $b.Groups[1].Value
  $chunk = $b.Groups[2].Value

  $title = ''
  $tm = [regex]::Match($chunk, 'title="([^"]+)"')
  if ($tm.Success) { $title = [System.Net.WebUtility]::HtmlDecode($tm.Groups[1].Value) }

  # the rate sits in the slider block, e.g. "עד 11%" or "5%"
  $rateText = ''
  $rm = [regex]::Match($chunk, '<h4[^>]*>(.*?)</h4>', 'Singleline')
  if ($rm.Success) {
    $rateText = ([System.Net.WebUtility]::HtmlDecode($rm.Groups[1].Value) -replace '<[^>]+>', ' ') -replace '\s+', ' '
    $rateText = $rateText.Trim()
  }

  $pct = 0.0
  $pm = [regex]::Match($rateText, '(\d+(?:\.\d+)?)\s*%')
  if ($pm.Success) { $pct = [double]$pm.Groups[1].Value }

  if ($slug) {
    $list.Add([pscustomobject]@{
      slug     = $slug
      name     = if ($title) { $title } else { $slug }
      rate_pct = $pct
      rate_text= $rateText
      url      = "https://www.pay-back.co.il/retailer/$slug"
    })
  }
}

$unique = $list | Group-Object slug | ForEach-Object { $_.Group[0] } | Sort-Object -Property rate_pct -Descending

$payload = [pscustomobject]@{
  source        = 'pay-back.co.il'
  program       = 'max PayBack'
  cards         = @('tau', 'behatsdaa')
  mechanic      = 'cashback'
  harvested_at  = (Get-Date -Format 'yyyy-MM-dd')
  count         = ($unique | Measure-Object).Count
  rules         = [pscustomobject]@{
    card_required   = 'max credit card only - NOT cash-card, debit, free or rechesh'
    excluded_from   = 'VAT, taxes, fees, shipping, gift wrap, discounts, credits, cancellations'
    stacking        = 'no stacking of promotions unless explicitly stated'
    installments    = 'computed on the full transaction amount'
    must_route      = 'must enter the shop through pay-back every time; no retroactive claims'
    aliexpress_cap  = 'max 150 ILS back per single AliExpress order'
  }
  retailers     = $unique
}

$outFile = Join-Path $outDir 'payback.json'
$payload | ConvertTo-Json -Depth 5 | Out-File -FilePath $outFile -Encoding utf8

Write-Host ''
Write-Host "retailers: $(($unique | Measure-Object).Count)"
Write-Host 'top rates:'
$unique | Select-Object -First 12 | ForEach-Object { Write-Host ("  {0,6}%  {1}" -f $_.rate_pct, $_.name) }
Write-Host "out: $outFile"
