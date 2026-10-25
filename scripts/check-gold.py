#!/usr/bin/env python3
"""Flag frames containing gold specks - the coins and sparkles Veo adds uninvited.

Looking at a contact sheet is not enough: at thumbnail size a handful of small
gold discs disappear, which is how two cuts shipped with coins still in them.
This counts the actual pixels instead.

    python scripts/check-gold.py ads/raw/*.mp4

Run it on the raw clips, not on a finished ad: the yellow number captions
are themselves gold and show up as a steady plateau around 5.

A pixel counts as gold when it is bright, strongly red-over-blue and clearly
yellow rather than skin. Warm cafe light and skin highlights sit below the
threshold; a coin or a spark sits well above it. Any frame over the limit is
printed with its timestamp so it can be cut out.
"""
import pathlib
import subprocess
import sys

FFMPEG = "ffmpeg"
WIDTH = 240          # small enough to be fast, big enough to keep a speck
LIMIT = 3.0          # mean of the gold mask, 0-255. Warm wood and skin
                     # highlights peak around 2; a single coin clears 5,
                     # a stream of them reaches 25 and up.

GOLD = ("gt(r(X,Y),185)*gt(g(X,Y),135)*lt(b(X,Y),115)"
        "*gt(r(X,Y)-b(X,Y),95)*gt(g(X,Y)-b(X,Y),50)")


def scan(path):
    expr = f"if({GOLD},255,0)"
    out = subprocess.run(
        [FFMPEG, "-v", "error", "-i", str(path),
         "-vf", (f"scale={WIDTH}:-2,format=rgb24,"
                 f"geq=r='{expr}':g='{expr}':b='{expr}',"
                 "format=gray,signalstats,"
                 "metadata=print:key=lavfi.signalstats.YAVG:file=-"),
         "-f", "null", "-"],
        capture_output=True, text=True).stdout

    hits, t = [], 0.0
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("frame:"):
            t = float(line.split("pts_time:")[1])
        elif "YAVG=" in line:
            v = float(line.split("=")[1])
            if v > LIMIT:
                hits.append((t, v))
    return hits


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    bad = 0
    for arg in argv:
        p = pathlib.Path(arg)
        hits = scan(p)
        if not hits:
            print(f"  clean  {p.name}")
            continue
        bad += 1
        lo, hi = hits[0][0], hits[-1][0]
        peak = max(h[1] for h in hits)
        print(f"  GOLD   {p.name}  {len(hits)} frames, "
              f"{lo:.2f}s-{hi:.2f}s, peak {peak:.2f}")
        for t, v in hits[:12]:
            print(f"           t={t:6.2f}  {v:.2f}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
