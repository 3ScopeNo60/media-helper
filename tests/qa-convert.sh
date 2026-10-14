#!/bin/bash
# Video -> Audio through the app's own code path (headless QA flag).
# usage: tests/qa-convert.sh <path to Media Helper.app> <tools dir> <work dir>
set -uo pipefail
APP="${1:?app}/Contents/MacOS/Media Helper"; TOOLS="${2:?tools dir}"; W="${3:?work dir}"
FF="$TOOLS/ffmpeg"; FP="$TOOLS/ffprobe"; C="$W/clips"; OUT="$W/converted"
rm -rf "$C" "$OUT" "$W/next"; mkdir -p "$C" "$OUT" "$W/next" "$W/support"
qa() { "$APP" "$@" -toolsDir "$TOOLS" -supportDir "$W/support" 2>&1 | tail -1; }
SRC=(-f lavfi -i "testsrc=size=320x240:rate=25:duration=5" -f lavfi -i "sine=frequency=440:duration=5")
$FF -v error -y "${SRC[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$C/clip mp4.mp4"
$FF -v error -y "${SRC[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$C/clip mov.mov"
$FF -v error -y "${SRC[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$C/clip m4v.m4v"
$FF -v error -y "${SRC[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$C/clip mkv.mkv"
$FF -v error -y "${SRC[@]}" -c:v libvpx-vp9 -b:v 300k -c:a libopus -shortest "$C/clip webm.webm"
$FF -v error -y "${SRC[@]}" -c:v mpeg4 -c:a libmp3lame -shortest "$C/clip avi.avi"
$FF -v error -y -f lavfi -i "testsrc=size=320x240:rate=25:duration=5" -c:v libx264 -pix_fmt yuv420p "$C/silent.mp4"
echo "this is not a video" > "$C/damaged.mp4"
echo "== test clips (streams)"
for f in "$C"/*; do printf "%-18s " "$(basename "$f")"; $FP -v error -show_entries stream=codec_name -of csv=p=0 "$f" 2>&1 | head -2 | tr '\n' ' '; echo; done
echo "== conversions"
for f in "clip mp4.mp4" "clip mov.mov" "clip m4v.m4v" "clip mkv.mkv" "clip webm.webm" "clip avi.avi"; do
  printf "%-16s -> mp3  " "$f"; qa -qaConvert "$C/$f" mp3 -saveTo "$OUT"; done
printf "%-16s -> m4a  " "clip mkv.mkv"; qa -qaConvert "$C/clip mkv.mkv" m4a -saveTo "$OUT"
printf "%-16s -> mp3 again (must not overwrite)  " "clip mp4.mp4"; qa -qaConvert "$C/clip mp4.mp4" mp3 -saveTo "$OUT"
printf "%-16s -> mp3  " "silent.mp4"; qa -qaConvert "$C/silent.mp4" mp3 -saveTo "$OUT"
printf "%-16s -> mp3  " "damaged.mp4"; qa -qaConvert "$C/damaged.mp4" mp3 -saveTo "$OUT"
cp "$C/clip mov.mov" "$W/next/"
printf "%-16s -> mp3 next to original  " "clip mov.mov"; qa -qaConvert "$W/next/clip mov.mov" mp3 -nextToOriginal
echo "== outputs (ffprobe: codec, duration)"
fail=0
for f in "$OUT"/* "$W"/next/*.mp3; do
  info=$($FP -v error -show_entries stream=codec_name:format=duration -of csv=p=0 "$f" | tr '\n' ' ')
  printf "%-28s %s\n" "$(basename "$f")" "$info"
done
echo "== leftover scratch folders: $(ls "${TMPDIR:-/tmp}" | grep -c '^MediaHelper-')"
