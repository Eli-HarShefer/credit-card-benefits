# max.co.il benefits harvester - covers the TAU card AND the Behatsdaa card
# (both are max-issued and share one catalogue + one pinuk pool).
#
#   powershell -ExecutionPolicy Bypass -File scripts\harvest-max.ps1
#
# The site is PUBLIC - no login. Two endpoints do the work:
#   /api/benefits/getLobby              -> categories + navBar (gives categoryEngName)
#   /api/benefits/getCategoriesLobby    -> paginated benefits per category (isLast flag)
#
# Gotcha: the payload has two keys differing only in case
# (customerNotEligbleUrl / customerNotEligbleURL). PowerShell's ConvertFrom-Json is
# case-insensitive and throws on that, so one is renamed before parsing.
#
# ASCII-only source (PowerShell 5.1 reads .ps1 as ANSI). Hebrew comes from the API.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'data'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36'
$H  = @{ 'User-Agent' = $UA; 'Accept' = 'application/json' }
$V  = 'V4.219-RC.5.39'

function Get-MaxJson {
  param([string]$Url)
  $raw = (Invoke-WebRequest -Uri $Url -Headers $H -UseBasicParsing -TimeoutSec 90).Content
  return ($raw -replace '"customerNotEligbleURL"', '"customerNotEligbleURL_alt"') | ConvertFrom-Json
}

function Strip-Html {
  param([string]$s)
  if ([string]::IsNullOrWhiteSpace($s)) { return '' }
  $t = $s -replace '<[^>]+>', ' '
  $t = [System.Net.WebUtility]::HtmlDecode($t)
  return ($t -replace '\s+', ' ').Trim()
}

# Classify how the benefit actually gets you money. This is the field that drives
# the "what do I have to remember to do" question.
function Get-Mechanic {
  param([string]$text)
  $pinuk  = [char]0x05EA + [char]0x05DE + [char]0x05D5 + [char]0x05E8 + [char]0x05EA   # "tmurat"
  $charge = [char]0x05D1 + [char]0x05DE + [char]0x05E2 + [char]0x05DE + [char]0x05D3   # "be-maamad"
  $cash   = [char]0x05E7 + [char]0x05D0 + [char]0x05E9 + [char]0x05D1 + [char]0x05E7   # "cashback"
  if ($text -match $charge) { return 'auto' }
  if ($text -match $pinuk)  { return 'spend-points' }
  if ($text -match $cash)   { return 'cashback' }
  return 'other'
}

# ---- 1. categories -------------------------------------------------------
Write-Host 'Fetching category list...'
$lobby = (Get-MaxJson "https://www.max.co.il/api/benefits/getLobby?v=$V").result
$cats  = $lobby.navBarCategories | Where-Object { $_.urlName } |
         ForEach-Object { [pscustomobject]@{ eng = $_.urlName; name = $_.name.Trim() } }
Write-Host "  categories: $($cats.Count)"

# ---- 2. page through each category ---------------------------------------
$all = [System.Collections.Generic.List[object]]::new()
$summary = [System.Collections.Generic.List[object]]::new()

foreach ($c in $cats) {
  Write-Host ("  [{0,-16}] {1,-32} " -f $c.eng, $c.name) -NoNewline
  $n = 0
  try {
    for ($page = 0; $page -lt 60; $page++) {
      $url = "https://www.max.co.il/api/benefits/getCategoriesLobby?isMobile=false&page=$page&loadLobby=true&category=$($c.eng)&club=undefined&region=undefined&v=$V"
      $res = (Get-MaxJson $url).result
      $batch = @($res.benefits)
      if ($batch.Count -eq 0) { break }

      foreach ($b in $batch) {
        $sub = Strip-Html $b.subTitle
        $all.Add([pscustomobject]@{
          id           = $b.id
          name         = $b.title
          offer        = $sub
          mechanic     = Get-Mechanic $sub
          badge        = if ($b.exclusiveText) { $b.exclusiveText.text } else { '' }
          category     = $c.name
          category_eng = $c.eng
          expires      = $b.publishingExpirationDate
          url          = $b.benefitUrl
          out_of_stock = [bool]$b.isOutOfStock
        })
        $n++
      }
      if ($res.isLast) { break }
      Start-Sleep -Milliseconds 150
    }
    $summary.Add([pscustomobject]@{ category = $c.name; eng = $c.eng; count = $n })
    Write-Host $n
  } catch {
    Write-Host "FAILED - $($_.Exception.Message)"
    $summary.Add([pscustomobject]@{ category = $c.name; eng = $c.eng; count = $n })
  }
  Start-Sleep -Milliseconds 250
}

# a benefit can sit in several categories - keep one row per benefit id
$unique = $all | Group-Object id | ForEach-Object {
  $g = $_.Group
  $o = $g[0]
  [pscustomobject]@{
    id           = $o.id
    name         = $o.name
    offer        = $o.offer
    mechanic     = $o.mechanic
    badge        = $o.badge
    categories   = ($g | ForEach-Object { $_.category } | Select-Object -Unique)
    expires      = $o.expires
    url          = $o.url
    out_of_stock = $o.out_of_stock
  }
}

$payload = [pscustomobject]@{
  source        = 'max.co.il'
  cards         = @('tau', 'behatsdaa')
  pool_note     = 'TAU and Behatsdaa are both max-issued: one shared catalogue and one shared pinuk pool (max 4/month, per ID, across all max cards).'
  harvested_at  = (Get-Date -Format 'yyyy-MM-dd')
  rows          = $all.Count
  unique        = ($unique | Measure-Object).Count
  categories    = $summary
  benefits      = $unique
}

$outFile = Join-Path $outDir 'max.json'
$payload | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding utf8

Write-Host ''
Write-Host '--------------------------------------------'
Write-Host "rows:   $($all.Count)"
Write-Host "unique: $(($unique | Measure-Object).Count)"
Write-Host 'by mechanic:'
$unique | Group-Object mechanic | Sort-Object Count -Descending |
  ForEach-Object { Write-Host ("  {0,-14} {1}" -f $_.Name, $_.Count) }
Write-Host "out:    $outFile"
