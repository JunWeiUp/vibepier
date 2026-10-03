#!/bin/sh
# Optional release step: credentials are stored in a notarytool Keychain profile.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool Keychain profile}"
: "${MACOS_SIGN_IDENTITY:?Set MACOS_SIGN_IDENTITY to a Developer ID Application identity}"
"$root/scripts/release/macos.sh"
version=$(cat "$root/VERSION")
archive="$root/dist/VibePier-$version-macos-arm64.zip"
xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$root/dist/staging/VibePier.app"
xcrun stapler validate "$root/dist/staging/VibePier.app"
spctl --assess --type execute --verbose "$root/dist/staging/VibePier.app"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$root/dist/staging/VibePier.app" "$archive"
# Validate the distributed bytes after extraction, including the stapled ticket.
verify_dir=$(mktemp -d "${TMPDIR:-/tmp}/vibepier-notary.XXXXXX")
trap 'rm -rf "$verify_dir"' EXIT HUP INT TERM
ditto -x -k "$archive" "$verify_dir"
xcrun stapler validate "$verify_dir/VibePier.app"
codesign --verify --deep --strict "$verify_dir/VibePier.app"
spctl --assess --type execute --verbose "$verify_dir/VibePier.app"
