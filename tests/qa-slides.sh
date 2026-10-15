#!/bin/bash
# Slides -> Images through the app's own code path (headless QA flag).
#   PDFs:        generated here (landscape, turned 90 degrees, cropped, portrait) and checked pixel by pixel.
#   Slide decks: pass a .pptx to also test the PowerPoint path, the Keynote path, the automatic choice, and a
#                .key made from it by Keynote. (macOS may ask "Allow Media Helper to control PowerPoint/Keynote?"
#                the first time; click OK.)
# usage: tests/qa-slides.sh <path to Media Helper.app> <work dir> [<a .pptx file to test with>]
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?app}/Contents/MacOS/Media Helper"; W="${2:?work dir}"; PPTX="${3:-}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
FX="$REPO/tests/out/slide-fixtures"; mkdir -p "$REPO/tests/out"
swiftc -O -o "$FX" "$REPO/tests/slide-fixtures.swift" 2>&1 | grep error
rm -rf "$W/qa-slides"; S="$W/qa-slides"; mkdir -p "$S/support"
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1 ${2:-}"; fail=1; }
qa()  { "$APP" -qaSlides "$@" -supportDir "$S/support" 2>&1; }
size_of() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixel/{printf "%s%s", sep, $2; sep="x"}'; }
want_size() { local got; got=$(size_of "$1"); [[ "$got" == "$2" ]] && ok "$3 ($got)" || bad "$3" "got $got, expected $2"; }
# want_color <image> <x> <y> <r> <g> <b> <name>   (tolerance 12 per channel)
want_color() { local out; out=$("$FX" pixel "$1" "$2" "$3" | cut -d' ' -f2-)
  awk -v got="$out" -v want="$4 $5 $6" 'BEGIN{split(got,g," ");split(want,w," ");for(i=1;i<=3;i++){d=g[i]-w[i];if(d<0)d=-d;if(d>12)exit 1}}' \
    && ok "$7 (pixel $2,$3 = $out)" || bad "$7" "pixel $2,$3 = $out, expected about $4 $5 $6"; }

echo "== PDF: 4 pages (landscape, turned 90 degrees, cropped, portrait)"
"$FX" make "$S/pdf" >/dev/null
r=$(qa "$S/pdf/pages.pdf" png -saveTo "$S/o1"); echo "$r" | tail -2
O="$S/o1/pages"
[[ $(ls "$O" | wc -l | tr -d ' ') == 4 ]] && ok "four pictures for four pages" || bad "picture count" "$(ls "$O")"
want_size "$O/pages_01.png" 1920x1080 "landscape page at Full HD"
want_size "$O/pages_02.png" 1920x3413 "turned page is portrait, 1920 wide"
want_size "$O/pages_03.png" 1920x1080 "cropped page uses the crop box shape (640x360)"
want_size "$O/pages_04.png" 1920x2485 "portrait page keeps its shape"
want_color "$O/pages_01.png" 20 20 255 38 0 "page 1: red square top-left"
want_color "$O/pages_01.png" 1900 1060 4 51 255 "page 1: blue square bottom-right"
want_color "$O/pages_01.png" 960 540 255 255 255 "page 1: unpainted area is white, not transparent"
want_color "$O/pages_02.png" 1900 20 255 38 0 "page 2: turned page, red square now top-right"
want_color "$O/pages_02.png" 20 3390 4 51 255 "page 2: turned page, blue square now bottom-left"
want_color "$O/pages_03.png" 20 20 255 38 0 "page 3: crop starts at the red square"
want_color "$O/pages_03.png" 20 1060 0 165 0 "page 3: nothing outside the crop box (no blue)"
want_color "$O/pages_04.png" 960 1200 0 165 0 "page 4: filled"

echo "== sizes, JPEG, prefix, never overwrite"
qa "$S/pdf/pages.pdf" jpeg -qaSize 4k -qaPrefix "Sunday_" -saveTo "$S/o2" | tail -1
want_size "$S/o2/pages/Sunday_pages_01.jpg" 3840x2160 "4K"
file "$S/o2/pages/Sunday_pages_01.jpg" | grep -q JPEG && ok "JPEG file really is a JPEG" || bad "JPEG"
qa "$S/pdf/pages.pdf" png -qaSize original -saveTo "$S/o3" | tail -1
want_size "$S/o3/pages/pages_01.png" 960x540 "original size, landscape"
want_size "$S/o3/pages/pages_02.png" 540x960 "original size, turned page"
want_size "$S/o3/pages/pages_03.png" 640x360 "original size, cropped page"
qa "$S/pdf/pages.pdf" png -saveTo "$S/o3" | tail -1 >/dev/null
[[ -d "$S/o3/pages 2" && -f "$S/o3/pages 2/pages_01.png" ]] && ok "second run goes to 'pages 2' (nothing overwritten)" || bad "no-overwrite" "$(ls "$S/o3")"
r=$(qa "$S/pdf/nothing.pdf" png -saveTo "$S/o4" | tail -1); [[ "$r" == QA_ERROR* ]] && ok "missing file: $r" || bad "missing file" "$r"
echo "not a pdf" > "$S/pdf/broken.pdf"; r=$(qa "$S/pdf/broken.pdf" png -saveTo "$S/o4" | tail -1); [[ "$r" == QA_ERROR* ]] && ok "damaged PDF: $r" || bad "damaged pdf" "$r"
[[ ! -e "$S/o4" || -z "$(ls "$S/o4")" ]] && ok "failed jobs leave nothing in the save folder" || bad "leftovers" "$(ls "$S/o4")"

if [[ -n "$PPTX" ]]; then
  echo "== PowerPoint deck ($(basename "$PPTX" | sed 's/.*\././'))"
  mkdir -p "$S/in"; cp "$PPTX" "$S/in/Test Deck.pptx"
  SUM1=$(shasum -a 256 "$S/in/Test Deck.pptx" | cut -d' ' -f1)
  office_open() { osascript -e 'tell application "System Events" to (name of every process) contains "Keynote" or (name of every process) contains "Microsoft PowerPoint"'; }
  for R in powerpoint keynote; do
    r=$(qa "$S/in/Test Deck.pptx" png -qaRenderer $R -saveTo "$S/o-$R"); echo "$r" | grep -E "QA_RENDERER|QA_RESULT|QA_ERROR"
    n=$(ls "$S/o-$R/Test Deck" 2>/dev/null | wc -l | tr -d ' ')
    [[ "$n" -ge 1 ]] && ok "$R: $n picture(s) made" || bad "$R" "$r"
    [[ -n "$(ls "$S/o-$R/Test Deck" 2>/dev/null)" ]] && want_size "$S/o-$R/Test Deck/Test Deck_01.png" 1920x1080 "$R: Full HD slide"
  done
  r=$(qa "$S/in/Test Deck.pptx" png -saveTo "$S/o-auto"); echo "$r" | grep -E "QA_RENDERER|QA_RESULT|QA_ERROR"
  echo "== Keynote file made from the deck"
  open -g -a Keynote "$S/in/Test Deck.pptx"; sleep 8
  osascript <<APPLESCRIPT 2>&1 | tail -1
tell application id "com.apple.iWork.Keynote"
  set d to document 1
  save d in POSIX file "$S/in/Test Deck.key"
  close d saving no
  quit
end tell
APPLESCRIPT
  sleep 2
  r=$(qa "$S/in/Test Deck.key" jpeg -saveTo "$S/o-key"); echo "$r" | grep -E "QA_RENDERER|QA_RESULT|QA_ERROR"
  ls "$S/o-key/Test Deck" 2>/dev/null | grep -q jpg && ok ".key converted by Keynote" || bad ".key" "$r"
  echo "== cancel half way"
  for R in powerpoint keynote; do
    r=$(qa "$S/in/Test Deck.pptx" png -qaRenderer $R -qaCancelAfter 2.5 -saveTo "$S/o-cancel" | tail -1)
    [[ "$r" == QA_CANCELLED ]] && ok "$R: cancelled" || bad "$R cancel" "$r"
    sleep 3
    [[ $(office_open) == false ]] && ok "$R: its document was closed again and the app quit" || bad "$R left open after cancel"
  done
  [[ ! -e "$S/o-cancel" || -z "$(ls "$S/o-cancel")" ]] && ok "cancelled jobs leave nothing in the save folder" || bad "cancel leftovers" "$(ls "$S/o-cancel")"
  sleep 3
  [[ $(office_open) == false ]] && ok "PowerPoint and Keynote were quit again (they weren't running before)" || bad "apps left running"
  [[ $(shasum -a 256 "$S/in/Test Deck.pptx" | cut -d' ' -f1) == "$SUM1" ]] && ok "the .pptx we handed in is unchanged" || bad "pptx changed"
  [[ -z "$(ls -A "$S/in" | grep -v -E '^Test Deck\.(pptx|key)$')" ]] && ok "no lock or temp files left next to the file" || bad "stray files" "$(ls -A "$S/in")"
fi
echo "== leftover scratch folders from this run: $(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'MediaHelper-*' -newer "$S/support" 2>/dev/null | wc -l | tr -d ' ')"
exit $fail
