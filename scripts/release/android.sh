#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
: "${ANDROID_KEYSTORE_PATH:?Set ANDROID_KEYSTORE_PATH outside the repository}"
: "${ANDROID_KEYSTORE_PASSWORD:?Set ANDROID_KEYSTORE_PASSWORD using secure storage}"
: "${ANDROID_KEY_ALIAS:?Set ANDROID_KEY_ALIAS}"
: "${ANDROID_KEY_PASSWORD:?Set ANDROID_KEY_PASSWORD using secure storage}"
snapshot=$(mktemp "${TMPDIR:-/tmp}/vibepier-source.XXXXXX")
trap 'rm -f "$snapshot"' EXIT HUP INT TERM
python3 "$root/scripts/release/provenance.py" begin "$snapshot"
"$root/apps/android/gradlew" -p "$root/apps/android" :app:assembleRelease --console=plain
python3 "$root/scripts/release/android-metadata.py" "$root/apps/android/app/build/outputs/apk/release/app-release.apk"
version=$(cat "$root/VERSION")
build=$(cat "$root/VERSION_CODE")
output="$root/dist/build-$build"
python3 "$root/scripts/release/provenance.py" publish "$snapshot" "$root/apps/android/app/build/outputs/apk/release/app-release.apk" "$output/VibePier-$version-android.apk"
python3 "$root/scripts/release/provenance.py" publish "$snapshot" "$root/apps/android/app/build/outputs/apk/release/app-release.apk.json" "$output/VibePier-$version-android.apk.json"
printf '%s\n' "Packaged signed Android APK in $output."
