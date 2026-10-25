#!/usr/bin/env python3
"""Lay the spoken lines onto a built ad, each one starting with its own shot.

    python scripts/mix-vo.py ad1 avri

Reads ads/<name>.edl for the running order, takes the matching line from
ads/vo/<voice>/, and delays it to the exact second its shot begins - which is
also the second its caption appears, so voice and subtitle start together.
The footage keeps its own ambience far down underneath, so the picture is not
dead silent while still leaving room for music added later.

Warns about any line that runs past the end of its shot instead of quietly
letting it spill into the next one.
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
AMBIENCE_DB = -24     # the clip's own room tone, kept well under the voice
VOICE_DB = 1.5        # a touch of lift so the voice sits clearly on phones


def read_edl(name):
    beats, t = [], 0.0
    for line in (ROOT / "ads" / f"{name}.edl").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        src, start, length, cap = line.split()
        beats.append({"cap": cap, "at": t, "len": float(length)})
        t += float(length)
    return beats, t


def duration(path):
    return float(subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", str(path)],
        capture_output=True, text=True).stdout.strip())


def main(argv):
    name = argv[0] if argv else "ad1"
    voice = argv[1] if len(argv) > 1 else "avri"
    video = ROOT / "ads" / f"{name}-rough.mp4"
    vodir = ROOT / "ads" / "vo" / voice
    out = ROOT / "ads" / f"{name}-{voice}.mp4"

    beats, total = read_edl(name)
    inputs, parts, over = ["-i", str(video)], [], []
    n = 1
    for b in beats:
        mp3 = vodir / f"{b['cap']}.mp3"
        if not mp3.exists():
            continue
        d = duration(mp3)
        if d > b["len"] + 0.02:
            over.append((b["cap"], d, b["len"]))
        inputs += ["-i", str(mp3)]
        parts.append(f"[{n}:a]adelay={int(b['at'] * 1000)}|{int(b['at'] * 1000)}[v{n}]")
        n += 1

    if over:
        print("  lines that outlast their shot:")
        for cap, d, l in over:
            print(f"    {cap}  speech {d:.2f}s > shot {l:.2f}s")

    mix = "".join(f"[v{i}]" for i in range(1, n))
    fc = (";".join(parts)
          + f";{mix}amix=inputs={n - 1}:normalize=0,volume={VOICE_DB}dB[vo]"
          + f";[0:a]volume={AMBIENCE_DB}dB[amb]"
          + ";[amb][vo]amix=inputs=2:normalize=0:duration=first,"
          # social players normalise to about -14 LUFS; arriving quieter just
          # means the platform turns it up and brings the room tone with it
          + "loudnorm=I=-14:TP=-1.5:LRA=11[a]")

    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", fc,
         "-map", "0:v", "-map", "[a]", "-c:v", "copy",
         "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", str(out)],
        check=True)

    print(f"\n{out.name}  {total:.1f}s  {out.stat().st_size:,} bytes  ({voice})")
    return 1 if over else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
