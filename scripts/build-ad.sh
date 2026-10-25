#!/usr/bin/env bash
# Assemble an ad rough cut from the Veo clips plus the rendered Hebrew captions.
#
#   bash scripts/build-ad.sh ad1
#
# Each line of ads/<name>.edl is:  source  start  length  caption
# where source is a file under ads/raw or ads/site, times are seconds, and
# caption is the id of a PNG under ads/caps (or "-" for none).
set -euo pipefail

cd "$(dirname "$0")/.."
NAME="${1:-ad1}"
EDL="ads/$NAME.edl"
WORK="ads/work/$NAME"
OUT="ads/$NAME-rough.mp4"
W=720 H=1280 FPS=24

rm -rf "$WORK"; mkdir -p "$WORK"

i=0
: > "$WORK/list.txt"
while read -r src start len cap; do
  [ -z "${src:-}" ] && continue
  case "$src" in \#*) continue;; esac
  i=$((i + 1))
  seg=$(printf "%s/%02d.mp4" "$WORK" "$i")
  fade_out=$(awk "BEGIN{print $len-0.35}")

  # input 0 is always the picture, input 1 the caption (when there is one),
  # and the audio comes either from the clip or from generated silence.
  if [[ "$src" == *.png ]]; then
    frames=$(awk "BEGIN{print int($len*$FPS)+$FPS}")
    vf="scale=$((W*2)):$((H*2)):flags=bicubic,zoompan=z='min(zoom+0.0006,1.08)':d=$frames:s=${W}x${H}:fps=$FPS"
    inputs=(-loop 1 -t "$len" -i "$src")
    [ "$cap" = "-" ] || inputs+=(-loop 1 -framerate "$FPS" -t "$len" -i "ads/caps/$cap.png")
    inputs+=(-f lavfi -t "$len" -i anullsrc=cl=stereo:r=48000)
    amap=$([ "$cap" = "-" ] && echo "1:a" || echo "2:a")
  else
    vf="scale=$W:$H,fps=$FPS"
    inputs=(-ss "$start" -t "$len" -i "$src")
    [ "$cap" = "-" ] || inputs+=(-loop 1 -framerate "$FPS" -t "$len" -i "ads/caps/$cap.png")
    amap="0:a"
  fi

  if [ "$cap" = "-" ]; then
    fc="[0:v]$vf,format=yuv420p[v]"
  else
    fc="[0:v]$vf[base];\
[1:v]format=rgba,fade=in:st=0:d=0.12:alpha=1[txt];\
[base][txt]overlay=0:0:format=auto,format=yuv420p[v]"
  fi

  ffmpeg -v error -y "${inputs[@]}" -filter_complex "$fc" \
    -map "[v]" -map "$amap" \
    -c:v libx264 -crf 18 -preset veryfast -pix_fmt yuv420p \
    -c:a aac -b:a 160k -ar 48000 -ac 2 -t "$len" "$seg"

  echo "file '$(basename "$seg")'" >> "$WORK/list.txt"
  printf "  %02d  %-26s %5ss  %s\n" "$i" "$(basename "$src")" "$len" "$cap"
done < "$EDL"

ffmpeg -v error -y -f concat -safe 0 -i "$WORK/list.txt" \
  -c:v libx264 -crf 18 -preset medium -pix_fmt yuv420p \
  -af "volume=-10dB" -c:a aac -b:a 160k -movflags +faststart "$OUT"

dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")
printf "\n%s  %.1fs  %s bytes\n" "$OUT" "$dur" "$(stat -c %s "$OUT")"
