#!/bin/bash
# Publishes a new Media Helper version that installed copies will offer to update to.
#
#   scripts/release.sh 1.1 "What changed, in a sentence or two"
#   scripts/release.sh 1.1 "notes" --dry-run     build and sign only; change nothing in git
#
# What it does: sets the version, builds, zips the app, signs the zip with the private
# key kept in this Mac's Keychain, commits the version bump, tags it v<version>,
# pushes, and creates the GitHub release with the zip and its signature attached.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version, e.g. 1.1> [\"release notes\"] [--dry-run]}"
NOTES="${2:-Media Helper $VERSION}"
DRY=false
if [[ "${3:-}" == "--dry-run" || "${2:-}" == "--dry-run" ]]; then
  DRY=true; [[ "${2:-}" == "--dry-run" ]] && NOTES="Media Helper $VERSION"
fi
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "Version must look like 1.1 or 1.2.3"; exit 1; }

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
TOOL_DIR="${MEDIAHELPER_RELEASE_DIR:-$HOME/.mediahelper-release}"
TOOL="$TOOL_DIR/release-tool"
[[ -x "$TOOL" ]] || { mkdir -p "$TOOL_DIR"; swiftc -O -o "$TOOL" scripts/release-tool.swift; }
"$TOOL" public >/dev/null || { echo "No signing key yet. Run: scripts/setup-updates.sh <owner/repo>"; exit 1; }

if ! $DRY; then
  [[ -z "$(git status --porcelain)" ]] || { echo "There are uncommitted changes. Commit them first, so the release matches what's in git."; exit 1; }
  git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "v$VERSION already exists."; exit 1; }
fi

# --- set the version (the build number goes up by one)
python3 - "$VERSION" <<'PY'
import re, sys
v = sys.argv[1]; s = open('project.yml').read()
s = re.sub(r'MARKETING_VERSION: "[^"]*"', f'MARKETING_VERSION: "{v}"', s, count=1)
m = re.search(r'CURRENT_PROJECT_VERSION: "(\d+)"', s)
s = s.replace(m.group(0), f'CURRENT_PROJECT_VERSION: "{int(m.group(1)) + 1}"', 1)
open('project.yml', 'w').write(s)
PY
restore() { if $DRY; then git checkout -- project.yml MediaHelper/Info.plist 2>/dev/null || true; fi; }
trap restore EXIT

./build.sh >/dev/null
APP="build/Media Helper.app"
[[ -d "$APP" ]] || { echo "Build failed."; exit 1; }
BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[[ "$BUILT" == "$VERSION" ]] || { echo "Built version is $BUILT, expected $VERSION."; exit 1; }
KEY=$(/usr/libexec/PlistBuddy -c "Print :MediaHelperUpdatePublicKey" "$APP/Contents/Info.plist" 2>/dev/null || true)
[[ "$KEY" == "$("$TOOL" public)" ]] || { echo "The app's built-in update key doesn't match your signing key. Run scripts/setup-updates.sh."; exit 1; }
lipo -archs "$APP/Contents/MacOS/Media Helper" | grep -q arm64 || { echo "The build isn't universal."; exit 1; }

# --- zip + sign
mkdir -p dist; ZIP="dist/MediaHelper-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sig"
ditto -c -k --keepParent "$APP" "$ZIP"
"$TOOL" sign "$ZIP" > "$ZIP.sig"
"$TOOL" verify "$ZIP" "$ZIP.sig" >/dev/null
echo "Built and signed: $ZIP ($(du -h "$ZIP" | cut -f1))"

if $DRY; then echo "Dry run: nothing committed, tagged or published."; exit 0; fi

# --- record it in git, then publish
git add project.yml MediaHelper/Info.plist
git commit -q -m "Release Media Helper $VERSION"
git tag "v$VERSION"
if git remote get-url origin >/dev/null 2>&1; then
  git push origin HEAD "v$VERSION"
  if command -v gh >/dev/null; then
    gh release create "v$VERSION" "$ZIP" "$ZIP.sig" --title "Media Helper $VERSION" --notes "$NOTES"
    echo "Published v$VERSION. Installed copies will offer it within 6 hours, or straight away from Media Helper > Check for Updates…"
  else
    echo "Pushed. Now create the release by hand: GitHub > Releases > Draft a new release, choose tag v$VERSION,"
    echo "attach $ZIP and $ZIP.sig, and publish. (Installing the 'gh' tool makes this automatic.)"
  fi
else
  echo "Tagged v$VERSION locally. There is no GitHub remote yet; see UPDATING.md to connect one."
fi
