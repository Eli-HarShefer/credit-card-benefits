#!/usr/bin/env python3
"""Speak every line of ads/vo.json in Hebrew, one file per line per voice.

Windows ships no Hebrew voice, so this uses Microsoft's neural Hebrew voices
through edge-tts: Avri (male) and Hila (female). Both are rendered so the two
can be compared on the finished ad, and because the cut is timed to whichever
of the two reads a line more slowly, either voice fits the same edit.

    python scripts/make-vo.py

Writes ads/vo/<voice>/<id>.mp3 and prints the duration of each line, which is
what the lengths in the .edl files are set from: a shot lasts as long as its
sentence plus a short breath.
"""
import asyncio
import json
import pathlib
import subprocess
import sys

import edge_tts

ROOT = pathlib.Path(__file__).resolve().parent.parent
VOICES = {"avri": "he-IL-AvriNeural", "hila": "he-IL-HilaNeural"}
RATE = "+18%"   # the default reads far slower than Eli does; this lands near
                #  his own pace of about two words a second
GAP = 0.50       # breath between sentences
MIN = 2.50       # no caption flashes past faster than this, however short
                 # the line - trimmed speech alone would leave some on
                 # screen for a second and a half


def duration(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", str(path)],
        capture_output=True, text=True).stdout.strip()
    return float(out)


TRIM = ("silenceremove=start_periods=1:start_duration=0:"
        "start_threshold=-45dB:detection=peak,areverse,"
        "silenceremove=start_periods=1:start_duration=0:"
        "start_threshold=-45dB:detection=peak,areverse")


async def speak(text, voice, out):
    """Render the line, then shave the silence off both ends.

    edge-tts pads about a quarter of a second of nothing before the first
    word. Left in, the caption would appear before the voice - the exact
    fault Eli caught in the first video.
    """
    raw = out.with_suffix(".raw.mp3")
    await edge_tts.Communicate(text, voice, rate=RATE).save(str(raw))
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(raw),
                    "-af", TRIM, "-c:a", "libmp3lame", "-q:a", "2", str(out)],
                   check=True)
    raw.unlink()


async def main():
    lines = json.loads((ROOT / "ads" / "vo.json").read_text(encoding="utf-8"))
    longest = {}
    for name, voice in VOICES.items():
        outdir = ROOT / "ads" / "vo" / name
        outdir.mkdir(parents=True, exist_ok=True)
        for key, text in lines.items():
            out = outdir / f"{key}.mp3"
            await speak(text, voice, out)
            d = duration(out)
            longest[key] = max(longest.get(key, 0.0), d)

    sys.stdout.reconfigure(encoding="utf-8")
    print(f"{'line':<8} {'speech':>7}  {'shot':>6}")
    for key in lines:
        print(f"{key:<8} {longest[key]:>7.2f}  {longest[key] + GAP:>6.2f}")
    print(f"\n{len(lines)} lines x {len(VOICES)} voices"
          f"  (shot = speech + {GAP:.2f}s)")


if __name__ == "__main__":
    asyncio.run(main())
