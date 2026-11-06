#!/usr/bin/env bash
# Builds the app and installs it in ~/Applications, where Spotlight, Raycast and Alfred find it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh "${1:-release}"

target="$HOME/Applications/MultiRecorder.app"
mkdir -p "$HOME/Applications"
rm -rf "$target"
ditto build/MultiRecorder.app "$target"
# Tell Launch Services and Spotlight about the new version.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target" || true
mdimport "$target" 2>/dev/null || true

echo "Installed $target"
