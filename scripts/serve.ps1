# Tiny static file server for previewing dashboard.html in a real browser.
#   powershell -ExecutionPolicy Bypass -File scripts\serve.ps1
# Then open http://localhost:8766/dashboard.html
# ASCII-only source (PowerShell 5.1 reads .ps1 as ANSI).

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add('http://localhost:8766/')
$listener.Start()
Write-Host 'serving on http://localhost:8766/'

$deadline = (Get-Date).AddMinutes(20)
while ($listener.IsListening -and (Get-Date) -lt $deadline) {
  $ctx = $listener.GetContext()
  $rel = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath).TrimStart('/')
  if ([string]::IsNullOrWhiteSpace($rel)) { $rel = 'dashboard.html' }
  $path = Join-Path $root $rel

  if (Test-Path $path -PathType Leaf) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $ctx.Response.ContentType = if ($path -like '*.html') { 'text/html; charset=utf-8' }
                                elseif ($path -like '*.json') { 'application/json; charset=utf-8' }
                                else { 'text/plain; charset=utf-8' }
    $ctx.Response.StatusCode = 200
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    Write-Host "200 $rel ($($bytes.Length))"
  } else {
    $ctx.Response.StatusCode = 404
    Write-Host "404 $rel"
  }
  $ctx.Response.Close()
}
$listener.Stop()
