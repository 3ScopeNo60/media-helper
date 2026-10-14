#!/bin/bash
# One-time setup for shipping updates: creates the signing key (kept in this Mac's Keychain)
# and builds its PUBLIC half into the app, so installed copies only accept updates you signed.
#
#   scripts/setup-updates.sh <owner/repo>     create the key (or reuse it), build the key and the
#                                             public GitHub repository name into project.yml
#   scripts/setup-updates.sh                  same, without changing the repository name
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
TOOL_DIR="${MEDIAHELPER_RELEASE_DIR:-$HOME/.mediahelper-release}"
TOOL="$TOOL_DIR/release-tool"
[[ -x "$TOOL" ]] || { mkdir -p "$TOOL_DIR"; swiftc -O -o "$TOOL" scripts/release-tool.swift; }

if PUB=$("$TOOL" public 2>/dev/null); then
  echo "Signing key already exists; reusing it."
else
  PUB=$("$TOOL" generate)
  echo "Created the signing key (private half is in your Keychain)."
fi

python3 - "$PUB" "${1:-}" <<'PY'
import re, sys
pub, repo = sys.argv[1], sys.argv[2]
s = open('project.yml').read()
s = re.sub(r'MediaHelperUpdatePublicKey: "[^"]*"', f'MediaHelperUpdatePublicKey: "{pub}"', s)
if repo: s = re.sub(r'MediaHelperUpdateRepo: "[^"]*"', f'MediaHelperUpdateRepo: "{repo}"', s)
open('project.yml', 'w').write(s)
PY
"$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)" generate >/dev/null
echo
echo "Public key built in: $PUB"
[[ -n "${1:-}" ]] && echo "Update source:       $1"
echo
echo "IMPORTANT: back up the private key. If this Mac is lost without a backup, installed copies can"
echo "never be updated again (they would need a fresh install). To show it for your password manager:"
echo "    $TOOL export"
echo
echo "Next: commit project.yml and MediaHelper/Info.plist, then build and install this version by hand once."
echo "After that, scripts/release.sh <version> \"notes\" publishes updates that installed copies will offer."
