#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
"$root/scripts/build/macos.sh"
version=$(cat "$root/VERSION")
archive="$root/dist/VibePier-$version-macos-arm64.zip"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$root/dist/staging/VibePier.app" "$archive"
bin=$(swift build --package-path "$root/apps/macos" -c release --arch arm64 --show-bin-path)
cli="$root/dist/staging/cli"
mkdir -p "$cli"
install -m 0755 "$bin/vibepier" "$cli/vibepier"
cp "$root/LICENSE" "$root/NOTICE" "$cli/"
COPYFILE_DISABLE=1 tar --no-xattrs --no-acls -czf "$root/dist/vibepier-$version-macos-arm64.tar.gz" -C "$cli" vibepier LICENSE NOTICE
printf '%s\n' "Packaged: $archive" "Preview builds without Developer ID notarization require macOS confirmation."
