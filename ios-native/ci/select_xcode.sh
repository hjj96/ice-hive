#!/bin/bash
# Select the newest installed stable Xcode (Xcode_XX.Y[.Z].app) on a GitHub macOS runner.
set -euo pipefail
latest=$(ls -d /Applications/Xcode_*.app 2>/dev/null | grep -E '/Xcode_[0-9]+(\.[0-9]+)*\.app$' | sort -V | tail -1 || true)
if [ -z "$latest" ]; then
  latest=$(xcode-select -p | sed 's#/Contents/Developer##')
fi
echo "Installed Xcodes:"; ls -d /Applications/Xcode*.app || true
echo "Selecting $latest"
sudo xcode-select -s "$latest/Contents/Developer"
xcodebuild -version
