#!/bin/sh
# Build and install vibepier-relay on a Linux server over ssh (interactive password prompts).
#   ./deploy.sh ubuntu@1.2.3.4 [amd64|arm64]     # non-root users run the install step with sudo
# Creates /etc/vibepier-relay/secret on first install without printing credentials.
# nginx is NOT edited here: add nginx-vibepier-relay.conf to the site by hand, then `nginx -t && systemctl reload nginx`.
set -eu
target=${1:?usage: deploy.sh user@host [amd64|arm64]}
arch=${2:-amd64}
cd "$(dirname "$0")"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -trimpath -ldflags='-s -w' -o "$out/vibepier-relay" ./cmd/vibepier-relay
cp relay.service "$out/vibepier-relay.service"
cat > "$out/vibepier-relay-install.sh" <<'EOF'
set -e
install -m 0755 /tmp/vibepier-relay /usr/local/bin/vibepier-relay
install -m 0644 /tmp/vibepier-relay.service /etc/systemd/system/vibepier-relay.service
rm -f /tmp/vibepier-relay /tmp/vibepier-relay.service /tmp/vibepier-relay-install.sh
install -d -m 0700 /etc/vibepier-relay
if [ ! -s /etc/vibepier-relay/secret ]; then
  (umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > /etc/vibepier-relay/secret)
  echo "Created relay secret at /etc/vibepier-relay/secret (root-only)."
fi
systemctl daemon-reload
systemctl enable vibepier-relay >/dev/null 2>&1
systemctl restart vibepier-relay
sleep 1
systemctl --no-pager --lines=5 status vibepier-relay
curl -s -o /dev/null -w "local check: HTTP %{http_code} (expect 426)\n" http://127.0.0.1:47801/
EOF
scp "$out/vibepier-relay" "$out/vibepier-relay.service" "$out/vibepier-relay-install.sh" "$target:/tmp/"
case "$target" in
  root@*) ssh "$target" 'sh /tmp/vibepier-relay-install.sh' ;;
  *) ssh -t "$target" 'sudo sh /tmp/vibepier-relay-install.sh' ;;
esac
