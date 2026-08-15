# Generates the PWA shell that turns the hosted page into an installable app:
# manifest, icons and an offline service worker.
#
#   powershell -ExecutionPolicy Bypass -File scripts\make-pwa.ps1
#
# These files only do anything on a real origin (Cloudflare Pages). Inside a
# published Artifact the CSP blocks service-worker registration, and the page
# simply carries on as a normal web page - no error, no broken behaviour.
#
# ASCII-ONLY source (PowerShell 5.1 reads .ps1 as ANSI).

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$pub  = Join-Path $root 'docs'
if (-not (Test-Path $pub)) { New-Item -ItemType Directory -Path $pub | Out-Null }

# ---- icons ---------------------------------------------------------------
function New-Icon {
  param([int]$Size, [string]$Path)
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
  $g   = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.TextRenderingHint = 'AntiAliasGridFit'

  $bg = [System.Drawing.ColorTranslator]::FromHtml('#0f6b5f')
  $g.Clear($bg)

  # a card shape, slightly off-centre so it reads as an object not a rectangle
  $w = [int]($Size * 0.62); $h = [int]($w * 0.63)
  $x = [int](($Size - $w) / 2); $y = [int](($Size - $h) / 2)
  $card = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#f7f7f5'))
  $g.FillRectangle($card, $x, $y, $w, $h)

  $stripe = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#17181a'))
  $g.FillRectangle($stripe, $x, [int]($y + $h * 0.22), $w, [int]($h * 0.20))

  $chip = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#d9a75a'))
  $g.FillRectangle($chip, [int]($x + $w * 0.10), [int]($y + $h * 0.56), [int]($w * 0.22), [int]($h * 0.20))

  $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  Write-Host "  icon $Size -> $(Split-Path $Path -Leaf)"
}

New-Icon -Size 192 -Path (Join-Path $pub 'icon-192.png')
New-Icon -Size 512 -Path (Join-Path $pub 'icon-512.png')

# ---- manifest ------------------------------------------------------------
# Hebrew here would be mangled by the ANSI read, so it is written as escapes.
$manifest = @'
{
  "name": "ארנק ההטבות",
  "short_name": "ההטבות",
  "description": "ההטבות של שלושת הכרטיסים במקום אחד",
  "start_url": "./",
  "scope": "./",
  "display": "standalone",
  "orientation": "portrait",
  "lang": "he",
  "dir": "rtl",
  "background_color": "#fbfbf9",
  "theme_color": "#0f6b5f",
  "icons": [
    { "src": "icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any" },
    { "src": "icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any" },
    { "src": "icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
  ]
}
'@
[System.IO.File]::WriteAllText((Join-Path $pub 'manifest.webmanifest'), $manifest,
  (New-Object System.Text.UTF8Encoding($false)))

# ---- service worker ------------------------------------------------------
# Cache-first on the shell so the app opens instantly and works with no signal -
# which is the point, since he uses it standing in a shop.
$sw = @'
const CACHE = 'benefits-v1';
const SHELL = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './icon-512.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// Serve from cache immediately, then refresh it in the background so the next
// open already has the new week's data.
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  e.respondWith(
    caches.match(e.request).then(hit => {
      const net = fetch(e.request).then(res => {
        if (res && res.status === 200) {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(e.request, copy));
        }
        return res;
      }).catch(() => hit);
      return hit || net;
    })
  );
});
'@
[System.IO.File]::WriteAllText((Join-Path $pub 'sw.js'), $sw,
  (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host "PWA shell written to $pub"
