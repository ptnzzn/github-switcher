#!/bin/zsh
# Build a universal release and package it as dist/GitHub-Switcher-<version>.zip.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh --no-install
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "build/GitHub Switcher.app/Contents/Info.plist")
mkdir -p dist
ZIP="dist/GitHub-Switcher-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "build/GitHub Switcher.app" "$ZIP"
shasum -a 256 "$ZIP"
