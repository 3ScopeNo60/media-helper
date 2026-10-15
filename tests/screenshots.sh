#!/bin/bash
# Launches the built app (with test folders and test flags only), captures its window by window ID,
# and quits it. No synthetic mouse or keyboard events are sent.
# (ONLY=slides in the environment takes only the Slides -> Images shots.)
# usage: tests/screenshots.sh <app> <tools dir> <work dir with clips/> <output dir> [<a .pptx for the slides shot>]
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?app}"; TOOLS="${2:?tools}"; W="${3:?work}"; OUT="${4:?out}"
BIN="$APP/Contents/MacOS/Media Helper"; WID="$REPO/tests/out/window-id"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
mkdir -p "$REPO/tests/out"
[[ -x "$WID" ]] || swiftc -O -o "$WID" "$REPO/tests/window-id.swift"
mkdir -p "$OUT" "$W/shots-save" "$W/shots-support"
quit_app() { pkill -f "$BIN" 2>/dev/null; sleep 1.5; }
launch() { open -n "$APP" --args -supportDir "$W/shots-support" -saveFolderPath "$W/shots-save" "$@"; }
snap() { # snap <name> <seconds to wait first>
  sleep "$2"
  local id; for i in $(seq 1 20); do id=$("$WID" "Media Helper") && break; sleep 0.5; done
  [[ -n "${id:-}" ]] || { echo "no window for $1"; return 1; }
  screencapture -l "$id" -o "$OUT/$1.png" && echo "saved $OUT/$1.png (window $id)"
}
quit_app
if [[ "${ONLY:-}" != slides ]]; then   # ONLY=slides takes just the Slides -> Images shots
echo "== first launch: tools not installed yet (empty tools folder)"
rm -rf "$W/fresh-tools"; launch -toolsDir "$W/fresh-tools"; snap 01-first-run-setup 5; quit_app
echo "== Download from YouTube: ready, update banner showing"
launch -toolsDir "$TOOLS" -updateFeed "$W/feed-good" -updateKey "$(cat "$W/other.pub")" -currentVersion 1.0; snap 02-download-ready 6; quit_app
echo "== Download from YouTube: a real video download finished"
rm -f "$W/shots-save"/*; launch -toolsDir "$TOOLS" -qaAutoDownload "https://www.youtube.com/watch?v=jNQXAC9IVRw" -qaAutoKind video; snap 03-download-finished 55; quit_app
echo "== Video -> Audio: real conversions (two fine, one silent, one damaged)"
rm -f "$W/shots-save"/*; C="$W/clips"
launch -toolsDir "$TOOLS" -qaSection convert -qaAutoConvert "$C/clip mp4.mp4" -qaAutoConvert "$C/clip mkv.mkv" -qaAutoConvert "$C/silent.mp4" -qaAutoConvert "$C/damaged.mp4"; snap 04-video-to-audio 9; quit_app
echo "== Video -> Audio: empty"
launch -toolsDir "$TOOLS" -qaSection convert; snap 05-video-to-audio-empty 5; quit_app
fi
echo "== Slides -> Images: empty"
launch -toolsDir "$TOOLS" -qaSection slides; snap 06-slides-to-images-empty 5; quit_app
if [[ -n "${5:-}" ]]; then   # optional 5th argument: a .pptx to turn into pictures (copied under a neutral name)
  echo "== Slides -> Images: real conversions (a PDF, a deck, a damaged PDF)"
  SW="$W/slides-in"; rm -rf "$SW"; mkdir -p "$SW"; rm -rf "$W/shots-save"/*
  cp "$5" "$SW/Sunday Slides.pptx"
  [[ -x "$REPO/tests/out/slide-fixtures" ]] || swiftc -O -o "$REPO/tests/out/slide-fixtures" "$REPO/tests/slide-fixtures.swift"
  "$REPO/tests/out/slide-fixtures" make "$SW/gen" >/dev/null && mv "$SW/gen/pages.pdf" "$SW/Announcements.pdf" && rmdir "$SW/gen"
  echo "not a pdf" > "$SW/Old handout.pdf"
  launch -toolsDir "$TOOLS" -qaSection slides -qaAutoSlides "$SW/Announcements.pdf" -qaAutoSlides "$SW/Sunday Slides.pptx" -qaAutoSlides "$SW/Old handout.pdf"; snap 07-slides-to-images 22; quit_app
fi
