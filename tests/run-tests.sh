#!/bin/bash
# Compiles the pure-logic core together with tests/main.swift and runs it. No Xcode project needed.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
OUT=tests/out; mkdir -p "$OUT"
swiftc -swift-version 5 -O -o "$OUT/unit-tests" MediaHelper/Core/*.swift tests/main.swift
"$OUT/unit-tests"
