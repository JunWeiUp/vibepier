#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
: "${ANDROID_KEYSTORE_PATH:?Set ANDROID_KEYSTORE_PATH outside the repository}"
: "${ANDROID_KEYSTORE_PASSWORD:?Set ANDROID_KEYSTORE_PASSWORD using secure storage}"
: "${ANDROID_KEY_ALIAS:?Set ANDROID_KEY_ALIAS}"
: "${ANDROID_KEY_PASSWORD:?Set ANDROID_KEY_PASSWORD using secure storage}"
"$root/apps/android/gradlew" -p "$root/apps/android" :app:assembleRelease --console=plain
python3 "$root/scripts/release/android-metadata.py" "$root/apps/android/app/build/outputs/apk/release/app-release.apk"
version=$(cat "$root/VERSION")
mkdir -p "$root/dist"
cp "$root/apps/android/app/build/outputs/apk/release/app-release.apk" "$root/dist/VibePier-$version-android.apk"
cp "$root/apps/android/app/build/outputs/apk/release/app-release.apk.json" "$root/dist/VibePier-$version-android.apk.json"
printf '%s\n' "Packaged signed Android APK in dist."
