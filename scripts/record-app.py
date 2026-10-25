#!/usr/bin/env python3
"""Record the short clip of the app used at the end of every ad.

Headless Chrome cannot be told to set localStorage before a page boots, so this
takes a copy of the built page, injects a bootstrap that picks the demo cards,
jumps to a view and hides the parts that do not belong in the shot, then shoots
it at 2x. ffmpeg animates that still, which gives motion that is perfectly
smooth and stays readable - a real screen recording judders and the map tiles
pop in halfway through.

Produces ads/site/app.mp4: a slow zoom into the map with its pins, then the
viewer's own cards with the benefits listed under each one.

    python scripts/record-app.py
"""
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
FFMPEG = "ffmpeg"
W, H = 720, 1280
FPS = 24

# the three cards the demo shows: mass-market ones, not a niche club
CARDS = '["hever","behatsdaa","shufersal"]'
RESULTS = "מסעדות ובתי קפה/גוש דן/בכל הארץ"

# the list under the map is noise in an ad - the map is the point
MAP_ONLY = """
  #res,#more,#foot,#filter,#pick,#tail,#nearbar,#nearTools,#actAll,#nearnote,
  #lede,#loc,#todo,#ali,#wallet,#mycards,#legend{display:none!important}
  #map{height:74vh!important;max-height:none!important;margin-top:12px}
"""
CARDS_ONLY = """
  #res,#more,#foot,#filter,#pick,#tail,#nearbar,#nearTools,#actAll,#nearnote,
  #lede,#loc,#todo,#ali,#map,#legend,#plot,#title,#wallet{display:none!important}
  #mycards{margin-top:8px}
"""

TMP = ROOT / "ads" / "tmp"
OUT = ROOT / "ads" / "site"


def boot(hash_, css):
    return (
        "<style>" + css + "</style>"
        "<script>try{"
        f"localStorage.setItem('cards.v1', '{CARDS}');"
        "localStorage.setItem('theme','light');"
        + (f"location.hash = {hash_!r};" if hash_ else "")
        + "}catch(e){}</script>"
    )


def shoot(name, hash_, css, tall=H):
    src = (ROOT / "docs" / "index.html").read_text(encoding="utf-8")
    anchor = '<meta charset="utf-8">'
    i = src.index(anchor) + len(anchor)
    page = TMP / f"{name}.html"
    page.write_text(src[:i] + boot(hash_, css) + src[i:], encoding="utf-8")

    shot = TMP / f"{name}.png"
    subprocess.run(
        [CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
         "--force-device-scale-factor=2", "--virtual-time-budget=20000",
         f"--window-size={W},{tall}", f"--screenshot={shot}", f"file:///{page}"],
        check=True, capture_output=True)
    return shot


def zoom(shot, out, seconds, z0, z1, cx=0.5, cy=0.5):
    """Push in from z0 to z1 on the point (cx, cy) of the shot."""
    frames = int(seconds * FPS)
    zexpr = f"{z0}+({z1 - z0})*on/{frames}"
    subprocess.run(
        [FFMPEG, "-v", "error", "-y", "-loop", "1", "-framerate", str(FPS),
         "-t", str(seconds), "-i", str(shot),
         "-f", "lavfi", "-t", str(seconds), "-i", "anullsrc=cl=stereo:r=48000",
         "-vf", (f"zoompan=z='{zexpr}'"
                 f":x='iw*{cx}-(iw/zoom)*{cx}':y='ih*{cy}-(ih/zoom)*{cy}'"
                 f":d=1:s={W}x{H}:fps={FPS},format=yuv420p"),
         "-map", "0:v", "-map", "1:a",
         "-c:v", "libx264", "-crf", "17", "-preset", "veryfast",
         "-c:a", "aac", "-b:a", "160k", "-shortest", str(out)],
        check=True, capture_output=True)


def pan(shot, out, seconds, y0, y1):
    """Pan from y0 to y1 down a tall shot (both in page pixels)."""
    frames = int(seconds * FPS)
    expr = f"{y0 * 2}+({(y1 - y0) * 2})*n/{frames}"
    subprocess.run(
        [FFMPEG, "-v", "error", "-y", "-loop", "1", "-framerate", str(FPS),
         "-t", str(seconds), "-i", str(shot),
         "-f", "lavfi", "-t", str(seconds), "-i", "anullsrc=cl=stereo:r=48000",
         "-vf", f"crop={W*2}:{H*2}:0:'{expr}',scale={W}:{H}:flags=bicubic,"
                f"fps={FPS},format=yuv420p",
         "-map", "0:v", "-map", "1:a",
         "-c:v", "libx264", "-crf", "17", "-preset", "veryfast",
         "-c:a", "aac", "-b:a", "160k", "-shortest", str(out)],
        check=True, capture_output=True)


def main():
    TMP.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)

    # two separate files, not one clip: each ad puts a different number of
    # sentences over the map, and a shared cut point would land mid-sentence
    zoom(shoot("map", RESULTS, MAP_ONLY), OUT / "app-map.mp4", 9.0,
         1.0, 1.34, 0.5, 0.45)
    pan(shoot("cards", None, CARDS_ONLY, tall=2000), OUT / "app-cards.mp4",
        4.0, 0, 330)

    shutil.rmtree(TMP, ignore_errors=True)
    for f in ("app-map.mp4", "app-cards.mp4"):
        print(f, (OUT / f).stat().st_size, "bytes")


if __name__ == "__main__":
    sys.exit(main())
