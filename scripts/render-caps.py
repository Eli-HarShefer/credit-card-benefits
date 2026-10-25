#!/usr/bin/env python3
"""Render the Hebrew on-screen layer for each beat of an ad, via headless Chrome.

Chrome does the bidi reordering and shaping, which PIL does not. Each entry in
ads/caps.json becomes ads/caps/<id>.png at 720x1280 with a transparent
background, holding up to three things:

  big   a large number or figure in the middle of the frame
  note  a small line under it (e.g. "לפי התקרות בתקנון")
  text  the subtitle, which is the voice line from ads/scripts.md verbatim

Layout follows the safe areas in ads/scripts.md: nothing important in the top
9%, the right 14% between 38% and 86% height, or the bottom 20%. The subtitle
sits about a quarter of the height up from the bottom, a little left of centre.

    python scripts/render-caps.py
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
W, H = 720, 1280

SAFE_RIGHT = 110   # clears the TikTok / Shorts button column
SAFE_LEFT = 48
SUB_BOTTOM = 280   # ~22% up from the bottom, above the caption/username strip

PAGE = """<!doctype html>
<html lang="he" dir="rtl"><head><meta charset="utf-8">
<link rel="stylesheet"
      href="https://fonts.googleapis.com/css2?family=Heebo:wght@700;900&display=block">
<style>
  html, body {{ margin:0; padding:0; width:{w}px; height:{h}px;
                background:transparent; overflow:hidden; }}
  body {{ position:relative; font-family:Heebo,'Segoe UI',Arial,sans-serif; }}

  .wash {{ position:absolute; inset:0; background:rgba(8,11,20,{wash}); }}

  .bigwrap {{ position:absolute; left:{left}px; right:{right}px; top:{bigtop}%;
              text-align:center; }}
  .pre {{ font-size:34px; font-weight:700; color:#e7eefc; margin-bottom:2px;
          text-shadow:0 2px 12px rgba(0,0,0,.9); }}
  .big {{ font-size:{bigsize}px; font-weight:900; color:{bigcolor};
          white-space:nowrap;
          line-height:1.05; letter-spacing:-0.03em;
          text-shadow:0 6px 40px rgba(0,0,0,.95), 0 2px 10px rgba(0,0,0,.9); }}
  .note {{ margin-top:14px; font-size:26px; font-weight:700; color:#cfe3ff;
           text-shadow:0 2px 12px rgba(0,0,0,.9); }}

  .scrim {{ position:absolute; left:0; right:0; bottom:0; height:52%;
            background:linear-gradient(to top,
              rgba(8,11,20,.94) 0%, rgba(8,11,20,.86) 38%,
              rgba(8,11,20,.40) 72%, rgba(8,11,20,0) 100%); }}
  .subwrap {{ position:absolute; left:{left}px; right:{right}px;
              bottom:{bottom}px; text-align:center; }}
  .t {{ font-size:{size}px; font-weight:900; line-height:1.18; color:{color};
        letter-spacing:-0.02em; white-space:pre-wrap;
        text-shadow:0 2px 14px rgba(0,0,0,.95); }}
</style></head>
<body>
  {washhtml}
  {bightml}
  {scrimhtml}
  {subhtml}
</body></html>
"""


def render(entry, out):
    big = entry.get("big", "")
    note = entry.get("note", "")
    text = entry.get("text", "")
    wash = entry.get("wash", 0)

    bightml = ""
    if big:
        bightml = (f'<div class="bigwrap">'
                   + (f'<div class="pre">{entry["pre"]}</div>' if entry.get("pre") else "")
                   + f'<div class="big">{big}</div>'
                   + (f'<div class="note">{note}</div>' if note else "")
                   + "</div>")

    html = PAGE.format(
        w=W, h=H,
        left=SAFE_LEFT, right=SAFE_RIGHT, bottom=entry.get("bottom", SUB_BOTTOM),
        bigtop=entry.get("bigtop", 34),
        wash=wash,
        washhtml='<div class="wash"></div>' if wash else "",
        bigsize=entry.get("bigsize", 108),
        bigcolor=entry.get("bigcolor", "#ffd466"),
        bightml=bightml,
        scrimhtml='<div class="scrim"></div>' if text else "",
        size=entry.get("size", 54),
        color=entry.get("color", "#ffffff"),
        subhtml=f'<div class="subwrap"><div class="t">{text}</div></div>' if text else "",
    )
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False,
                                     encoding="utf-8") as fh:
        fh.write(html)
        path = fh.name
    try:
        subprocess.run(
            [CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
             "--default-background-color=00000000",
             "--virtual-time-budget=4000",
             f"--window-size={W},{H}",
             f"--screenshot={out}", f"file:///{path}"],
            check=True, capture_output=True)
    finally:
        os.unlink(path)


def main():
    caps = json.loads((ROOT / "ads" / "caps.json").read_text(encoding="utf-8"))
    outdir = ROOT / "ads" / "caps"
    outdir.mkdir(parents=True, exist_ok=True)
    for entry in caps:
        out = outdir / f"{entry['id']}.png"
        render(entry, str(out))
    print(f"{len(caps)} captions rendered")


if __name__ == "__main__":
    sys.exit(main())
