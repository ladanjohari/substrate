#!/bin/bash
# Double-click this to open Substrate.
#
# It builds the app if it needs building, starts it, and gets out of the way.
# The app puts a dot in your menu bar, top right. Click the dot for the panel;
# "Open the full tree" in the panel opens the window.
#
# The app starts the store itself if nothing is already serving it, and stops
# it again when you quit. You can close this Terminal window once the app is up.

cd "$(dirname "$0")/app/mac" || exit 1

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is not installed. Install Xcode or the command line tools first:"
  echo "    xcode-select --install"
  read -r -p "Press return to close."
  exit 1
fi

echo "Building..."
if ! swift build; then
  echo ""
  echo "The build failed. The errors are above."
  read -r -p "Press return to close."
  exit 1
fi

# One at a time. A second copy would put a second dot in the menu bar.
pkill -x SubstrateBar 2>/dev/null
sleep 1

echo ""
echo "Substrate is running. Look for the dot in your menu bar, top right."
echo "Quit from the panel, or close this window to stop it."
.build/debug/SubstrateBar
