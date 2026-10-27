#!/bin/zsh
# Build GitHub Switcher.app (universal: arm64 + x86_64) and install it to
# ~/Applications. Pass --no-install to only build into build/.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"
INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

APP="build/GitHub Switcher.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos13.0" \
    Sources/main.swift -o "build/GitHubSwitcher-$arch"
done
lipo -create build/GitHubSwitcher-arm64 build/GitHubSwitcher-x86_64 \
  -output "$APP/Contents/MacOS/GitHubSwitcher"

# App icon: Icon/icon.png (1024px, from Icon/make_icon.swift) -> AppIcon.icns
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Icon/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Icon/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GitHub Switcher</string>
  <key>CFBundleIdentifier</key><string>com.ptnzzn.github-switcher</string>
  <key>CFBundleExecutable</key><string>GitHubSwitcher</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Opens Terminal to sign in to a new GitHub account.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

echo "Built: $APP ($VERSION)"
(( INSTALL )) || exit 0

mkdir -p ~/Applications
rm -rf ~/Applications/"GitHub Switcher.app"
cp -R "$APP" ~/Applications/
echo "Installed: ~/Applications/GitHub Switcher.app"
