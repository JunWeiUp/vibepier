#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
version=$(cat "$root/VERSION")
mkdir -p "$root/dist"
for arch in amd64 arm64; do
    stage="$root/dist/staging/relay-$arch"
    mkdir -p "$stage"
    (cd "$root/services/relay" && CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -trimpath -ldflags='-s -w' -o "$stage/vibepier-relay" ./cmd/vibepier-relay)
    cp "$root/LICENSE" "$root/NOTICE" "$root/services/relay/relay.service" "$root/services/relay/nginx-vibepier-relay.conf" "$stage/"
    COPYFILE_DISABLE=1 tar --no-xattrs --no-acls -czf "$root/dist/vibepier-relay-$version-linux-$arch.tar.gz" -C "$stage" vibepier-relay LICENSE NOTICE relay.service nginx-vibepier-relay.conf
done
