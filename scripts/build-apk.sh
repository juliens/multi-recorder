#!/usr/bin/env bash
# Builds the Android app (MultiRecorder Phone) to build/MultiRecorderPhone.apk.
# Needs the Android SDK (ANDROID_HOME, or ~/Library/Android/sdk) and a JDK 17.
# Without a JDK on the PATH, it uses one from nixpkgs.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/android"

sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [ ! -d "$sdk" ]; then
    echo "Android SDK not found. Set ANDROID_HOME." >&2
    exit 1
fi
echo "sdk.dir=$sdk" > local.properties

build() {
    ./gradlew --no-daemon -q assembleRelease
}

if java -version >/dev/null 2>&1; then
    build
else
    nix shell nixpkgs#jdk17 --command bash -c "$(declare -f build); build"
fi

mkdir -p "$root/build"
cp app/build/outputs/apk/release/app-release.apk "$root/build/MultiRecorderPhone.apk"
echo "Built build/MultiRecorderPhone.apk"
