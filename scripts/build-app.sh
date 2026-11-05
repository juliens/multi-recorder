#!/usr/bin/env bash
# Builds build/MultiRecorder.app. The bundle is needed for the camera and microphone permission prompts.
set -euo pipefail
cd "$(dirname "$0")/.."

config="${1:-release}"
swift build -c "$config"
bin_dir="$(swift build -c "$config" --show-bin-path)"

app="build/MultiRecorder.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/MultiRecorder" "$app/Contents/MacOS/MultiRecorder"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"

echo "Built $app"
