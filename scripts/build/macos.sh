#!/bin/sh
# Build and stage an app bundle. Never installs, launches, or edits user settings.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
macos="$root/apps/macos"
stage="$root/dist/staging/VibePier.app"
version=$(cat "$root/VERSION")
build=$(cat "$root/VERSION_CODE")

if ! command -v go >/dev/null 2>&1; then
    echo "Go is required to build the bundled VibePierFileServer; install Go 1.22 or newer." >&2
    exit 1
fi

swift build --package-path "$macos" -c release --arch arm64 --product VibePierApp
swift build --package-path "$macos" -c release --arch arm64 --product vibepier
bin=$(swift build --package-path "$macos" -c release --arch arm64 --show-bin-path)

# The destination is a fixed generated path, never a user installation.
rm -rf "$stage"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go -C "$root/services/relay" build -trimpath -ldflags="-s -w" -o "$stage/Contents/MacOS/VibePierFileServer" ./cmd/vibepier-file-server
install -m 0755 "$bin/VibePierApp" "$stage/Contents/MacOS/VibePier"
cp "$macos/Resources/Info.plist" "$stage/Contents/Info.plist"
cp "$macos/Resources/VibePier.icns" "$stage/Contents/Resources/"
cp "$root/LICENSE" "$root/NOTICE" "$stage/Contents/Resources/"
for locale in "$macos"/Resources/*.lproj; do
    [ ! -d "$locale" ] || cp -R "$locale" "$stage/Contents/Resources/"
done
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version%%-*}" "$stage/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$stage/Contents/Info.plist"

if [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then
    case "$MACOS_SIGN_IDENTITY" in
        "Developer ID Application:"*) ;;
        *) echo "Public distribution requires a Developer ID Application identity; omit MACOS_SIGN_IDENTITY for an ad-hoc preview." >&2; exit 1 ;;
    esac
    codesign --force --timestamp --options runtime --identifier VibePierFileServer --sign "$MACOS_SIGN_IDENTITY" "$stage/Contents/MacOS/VibePierFileServer"
    codesign --force --timestamp --options runtime --entitlements "$macos/Resources/VibePier.entitlements" --sign "$MACOS_SIGN_IDENTITY" "$stage"
else
    codesign --force --identifier VibePierFileServer --sign - "$stage/Contents/MacOS/VibePierFileServer"
    codesign --force --sign - "$stage"
fi
codesign --verify --deep --strict "$stage"
printf '%s\n' "Staged app: $stage"
