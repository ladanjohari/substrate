#!/bin/bash
# Build Substrate.app.
#
# `swift build` makes a bare executable. That runs, but it has no icon, it
# cannot be opened at login, and it is not a thing you can put in
# Applications. This wraps the same binary in the bundle macOS expects.
#
#     ./make-app.sh            builds Substrate.app next to this file
#
# It is not signed or notarised. That is the App Store piece, and it is not in
# this window. Unsigned means macOS asks once, on first open, whether you meant
# to run it.

set -e
cd "$(dirname "$0")"

APP="Substrate.app"
ID="tools.substrate.menubar"
VERSION="0.1.0"

echo "Building..."
swift build -c release

if [ ! -f Substrate.icns ]; then
  echo "Drawing the icon..."
  python3 make-icon.py
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SubstrateBar "$APP/Contents/MacOS/Substrate"
cp Substrate.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>Substrate</string>
  <key>CFBundleDisplayName</key>        <string>Substrate</string>
  <key>CFBundleExecutable</key>         <string>Substrate</string>
  <key>CFBundleIdentifier</key>         <string>$ID</string>
  <key>CFBundleIconFile</key>           <string>Substrate</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundleVersion</key>            <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>     <string>14.0</string>
  <!-- A menu bar app. No Dock icon, no window in the app switcher. -->
  <key>LSUIElement</key>                <true/>
</dict>
</plist>
PLIST

# The store lives in the repo, and the app walks up from its own binary to
# find it. Inside a bundle that walk ends at the bundle, so leave a marker
# pointing home rather than making the app guess.
REPO="$(cd ../.. && pwd)"
printf '%s\n' "$REPO" > "$APP/Contents/Resources/repo-path"

touch "$APP"
echo ""
echo "Built $APP"
echo "Drag it to /Applications, or double-click it where it is."
echo "It is unsigned, so the first open asks whether you meant it."
