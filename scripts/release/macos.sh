#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
snapshot=$(mktemp "${TMPDIR:-/tmp}/vibepier-source.XXXXXX")
trap 'rm -f "$snapshot"' EXIT HUP INT TERM
python3 "$root/scripts/release/provenance.py" begin "$snapshot"
"$root/scripts/build/macos.sh"
version=$(cat "$root/VERSION")
build=$(cat "$root/VERSION_CODE")
output="$root/dist/build-$build"
archive="$root/dist/staging/VibePier-$version-macos-arm64.zip"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$root/dist/staging/VibePier.app" "$archive"
if [ "${VIBEPIER_NOTARY_STAGE:-0}" != 1 ]; then
    python3 "$root/scripts/release/provenance.py" publish "$snapshot" "$archive" "$output/$(basename "$archive")"
fi
bin=$(swift build --package-path "$root/apps/macos" -c release --arch arm64 --show-bin-path)
cli="$root/dist/staging/cli"
mkdir -p "$cli"
install -m 0755 "$bin/vibepier" "$cli/vibepier"
install -m 0755 "$root/dist/staging/VibePier.app/Contents/MacOS/VibePierFileServer" "$cli/VibePierFileServer"
cp "$root/LICENSE" "$root/NOTICE" "$cli/"
COPYFILE_DISABLE=1 tar --no-xattrs --no-acls -czf "$root/dist/staging/vibepier-$version-macos-arm64.tar.gz" -C "$cli" vibepier VibePierFileServer LICENSE NOTICE
python3 "$root/scripts/release/provenance.py" publish "$snapshot" "$root/dist/staging/vibepier-$version-macos-arm64.tar.gz" "$output/vibepier-$version-macos-arm64.tar.gz"
printf '%s\n' "Packaged: $output" "Preview builds without Developer ID notarization require macOS confirmation."
