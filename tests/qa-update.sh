#!/bin/bash
# End-to-end test of the app's self-update, using THROWAWAY keys and a local feed.
# Never touches /Applications, the real signing key, GitHub, or the real Application Support folder.
#
# usage: tests/qa-update.sh <tools dir (already installed)> <work dir>
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${1:?tools dir}"; W="${2:?work dir}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
# Never leave a throwaway key behind: it lives under a unique, clearly-named Keychain entry.
export RELEASE_TOOL_SERVICE="Media Helper TEST throwaway $$"
export MEDIAHELPER_RELEASE_DIR="$W/release-tool-dir"
mkdir -p "$REPO/tests/out"
[[ -x "$REPO/tests/out/sign-helper" ]] || swiftc -O -o "$REPO/tests/out/sign-helper" "$REPO/tests/sign-helper.swift"
cleanup() { security delete-generic-password -s "$RELEASE_TOOL_SERVICE" >/dev/null 2>&1; }
trap cleanup EXIT
pass=0; failn=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "PASS  $1"; else failn=$((failn+1)); echo "FAIL  $1"; fi; }
ver() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist"; }

rm -rf "$W"; mkdir -p "$W"
echo "== 1. Build a 1.0 app that carries a throwaway key, and release 1.1 with the real release scripts (dry run)"
rsync -a --exclude build --exclude dist --exclude '*.xcodeproj' --exclude tests/out --exclude .git "$REPO/" "$W/relrepo/"
( cd "$W/relrepo" && git init -q -b main && git config user.name Test && git config user.email t@local && git add -A && git commit -q -m base \
  && scripts/setup-updates.sh testowner/testrepo | grep -E "Created|Public key|Update source" \
  && git commit -qam "key" && ./build.sh | grep -E "Built|Deployment" \
  && mkdir -p "$W/old" && cp -R "build/Media Helper.app" "$W/old/" \
  && scripts/release.sh 1.1 "Test notes for 1.1" --dry-run | tail -2 )
OLD="$W/old/Media Helper.app"; ZIP="$W/relrepo/dist/MediaHelper-1.1.zip"; SIG="$ZIP.sig"
PLISTKEY=$(/usr/libexec/PlistBuddy -c "Print :MediaHelperUpdatePublicKey" "$OLD/Contents/Info.plist")
PLISTREPO=$(/usr/libexec/PlistBuddy -c "Print :MediaHelperUpdateRepo" "$OLD/Contents/Info.plist")
ok "the 1.0 app being tested is really 1.0" '[[ "$(ver "$OLD")" == "1.0" ]]'
ok "built app carries the throwaway public key and repo ($PLISTREPO)" '[[ -n "$PLISTKEY" && "$PLISTREPO" == "testowner/testrepo" ]]'
ok "release-tool verifies the signature release.sh made" '"$MEDIAHELPER_RELEASE_DIR/release-tool" verify "$ZIP" "$SIG" | grep -q OK'
ok "release zip contains Media Helper.app at version 1.1" 'unzip -p "$ZIP" "Media Helper.app/Contents/Info.plist" | grep -q "<string>1.1</string>"'
ok "release.sh --dry-run restored project.yml (version back to 1.0)" 'grep -q "MARKETING_VERSION: \"1.0\"" "$W/relrepo/project.yml"'

mkfeed() { # mkfeed <dir> <tag> <zip> <sig> [extra releases]
  mkdir -p "$1"; local z; z="$(basename "$3")"
  cp "$3" "$1/$z"; cp "$4" "$1/$z.sig"
  cat > "$1/releases.json" <<JSON
[{"tag_name":"v9.9","name":"draft","body":"","draft":true,"prerelease":false,"assets":[]},
 {"tag_name":"v0.9","name":"old","body":"old","draft":false,"prerelease":false,"assets":[]},
 {"tag_name":"$2","name":"Media Helper","body":"Test notes for ${2#v}","draft":false,"prerelease":false,
  "assets":[{"name":"$z","size":1,"browser_download_url":"file://$1/$z"},{"name":"$z.sig","size":1,"browser_download_url":"file://$1/$z.sig"}]}]
JSON
}
mkfeed "$W/feed-good" v1.1 "$ZIP" "$SIG"
installcopy() { rm -rf "$W/apps/$1"; mkdir -p "$W/apps/$1"; cp -R "$OLD" "$W/apps/$1/"; echo "$W/apps/$1/Media Helper.app"; }
run() { local app="$1"; shift; "$app/Contents/MacOS/Media Helper" "$@" -toolsDir "$TOOLS" 2>&1 | tail -3; }

echo "== 2. Offers"
A=$(installcopy A)
out=$(run "$A" -qaUpdateCheck -updateFeed "$W/feed-good" -supportDir "$W/supA"); echo "$out"
ok "newer version (1.1) is offered, with its notes; drafts and older tags ignored" 'echo "$out" | grep -q "QA_UPDATE available version=1.1 notes=Test notes for 1.1"'
out=$(run "$A" -qaUpdateCheck -updateFeed "$W/feed-good" -supportDir "$W/supA" -currentVersion 1.1); echo "$out"
ok "no update offered when already on 1.1" 'echo "$out" | grep -q "QA_UPDATE up-to-date"'
out=$(run "$A" -qaUpdateCheck -supportDir "$W/supA"); echo "$out"
ok "with no feed override the app asks GitHub for the (nonexistent) test repo and says so plainly" 'echo "$out" | grep -q "QA_UPDATE problem: The update source wasn.t found"'

echo "== 3. Refusals (app must stay at 1.0, nothing installed)"
# 3a. zip altered after signing
mkdir -p "$W/tamper"; cp "$ZIP" "$W/tamper/MediaHelper-1.1.zip"; printf 'x' >> "$W/tamper/MediaHelper-1.1.zip"; cp "$SIG" "$W/tamper/MediaHelper-1.1.zip.sig"
mkfeed "$W/feed-tampered" v1.1 "$W/tamper/MediaHelper-1.1.zip" "$W/tamper/MediaHelper-1.1.zip.sig"
B=$(installcopy B)
out=$(run "$B" -qaUpdateInstall -updateFeed "$W/feed-tampered" -supportDir "$W/supB"); echo "$out"
ok "bad signature (zip altered after signing) is REFUSED" 'echo "$out" | grep -q "security check, so it was NOT installed"'
ok "  ...and the app is untouched (still 1.0), no backup made" '[[ "$(ver "$B")" == "1.0" && ! -d "$W/supB/Updates/Previous" ]]'
# 3b. signed by some other key
"$REPO/tests/out/sign-helper" gen "$W/other.key" > "$W/other.pub"
"$REPO/tests/out/sign-helper" sign "$W/other.key" "$ZIP" > "$W/other.sig"
mkfeed "$W/feed-wrongkey" v1.1 "$ZIP" "$W/other.sig"
C=$(installcopy C)
out=$(run "$C" -qaUpdateInstall -updateFeed "$W/feed-wrongkey" -supportDir "$W/supC"); echo "$out"
ok "signature from a different key is REFUSED" 'echo "$out" | grep -q "security check, so it was NOT installed" && [[ "$(ver "$C")" == "1.0" ]]'
# 3c. valid signature but the zip's version isn't the announced one
cp "$ZIP" "$W/tamper/MediaHelper-1.2.zip"; "$MEDIAHELPER_RELEASE_DIR/release-tool" sign "$W/tamper/MediaHelper-1.2.zip" > "$W/tamper/MediaHelper-1.2.zip.sig"
mkfeed "$W/feed-mismatch" v1.2 "$W/tamper/MediaHelper-1.2.zip" "$W/tamper/MediaHelper-1.2.zip.sig"
D=$(installcopy D)
out=$(run "$D" -qaUpdateInstall -updateFeed "$W/feed-mismatch" -supportDir "$W/supD"); echo "$out"
ok "correctly signed zip whose version differs from the announced one is REFUSED" 'echo "$out" | grep -q "version doesn.t match" && [[ "$(ver "$D")" == "1.0" ]]'
# 3d. no key at all
E0=$(installcopy E0)
out=$("$E0/Contents/MacOS/Media Helper" -qaUpdateCheck -updateFeed "$W/feed-good" -supportDir "$W/supE0" -updateKey "" -toolsDir "$TOOLS" 2>&1 | tail -1); echo "$out"
ok "an app with no update key refuses to update at all" 'echo "$out" | grep -q "no update key"'

echo "== 4. Install: swap + relaunch (real signed release zip, key from Info.plist)"
G=$(installcopy G)
pkill -f "$G/Contents/MacOS" 2>/dev/null
out=$(run "$G" -qaUpdateInstall -updateFeed "$W/feed-good" -supportDir "$W/supG"); echo "$out"
ok "install reported hand-over to the swap script" 'echo "$out" | grep -q "relaunching"'
for i in $(seq 1 40); do [[ "$(ver "$G")" == "1.1" ]] && pgrep -f "$G/Contents/MacOS" >/dev/null && break; sleep 0.5; done
ok "the app at the same path is now version 1.1" '[[ "$(ver "$G")" == "1.1" ]]'
ok "the previous version (1.0) is kept as a backup" '[[ "$(ver "$W/supG/Updates/Previous/Media Helper.app")" == "1.0" ]]'
ok "the new version was relaunched (process running from the updated path)" 'pgrep -f "$G/Contents/MacOS" >/dev/null'
ok "the new copy is validly signed" 'codesign --verify --deep --strict "$G"'
pgrep -fl "$G/Contents/MacOS" | head -2
pkill -f "$G/Contents/MacOS" 2>/dev/null; sleep 1

echo "== 5. Install with the -updateKey QA flag (zip signed by a different throwaway key, not the baked-in one)"
"$REPO/tests/out/sign-helper" sign "$W/other.key" "$ZIP" > "$W/other2.sig"
mkfeed "$W/feed-flagkey" v1.1 "$ZIP" "$W/other2.sig"
H=$(installcopy H)
out=$(run "$H" -qaUpdateInstall -updateFeed "$W/feed-flagkey" -updateKey "$(cat "$W/other.pub")" -supportDir "$W/supH"); echo "$out"
for i in $(seq 1 40); do [[ "$(ver "$H")" == "1.1" ]] && break; sleep 0.5; done
ok "-updateKey override accepts a zip signed by that key and installs 1.1" '[[ "$(ver "$H")" == "1.1" ]]'
sleep 2; pkill -f "$H/Contents/MacOS" 2>/dev/null

echo; echo "$pass passed, $failn failed"
exit $((failn > 0))
