#!/bin/sh
# Switches a USB-connected phone to wireless ADB on port 5555, so later installs and screenshots need no cable.
# The phone and the Mac must share a Wi-Fi network; the mode lasts until the phone reboots.
#
#   android/adb-wifi.sh          # the only USB phone
#   android/adb-wifi.sh Mi_10    # the phone whose serial or model matches
#   android/adb-wifi.sh 192.168.31.20   # reconnect to a known address without USB
set -eu

ADB="${ADB:-$(command -v adb || echo "$HOME/Library/Android/sdk/platform-tools/adb")}"
PORT="${PORT:-5555}"
target="${1:-}"

case "$target" in
    *.*.*.*:*) exec "$ADB" connect "$target" ;;
    *.*.*.*) exec "$ADB" connect "$target:$PORT" ;;
esac

# Only USB devices: wireless serials contain a colon.
serials=$("$ADB" devices -l | awk 'NR > 1 && $2 == "device" && $1 !~ /:/' | grep -i -- "$target" | awk '{ s = s $1 " " } END { printf "%s", s }' || true)
set -- $serials
if [ $# -ne 1 ]; then
    echo "需要恰好一台用 USB 连接并已授权的手机${target:+（匹配 $target）}，当前找到 $# 台：" >&2
    "$ADB" devices -l >&2
    exit 1
fi
serial=$1

address=$("$ADB" -s "$serial" shell ip -f inet addr show wlan0 | awk '/inet / { sub("/.*", "", $2); a = $2 } END { printf "%s", a }')
[ -n "$address" ] || { echo "手机没有连接 Wi-Fi（wlan0 无 IPv4 地址）" >&2; exit 1; }

"$ADB" -s "$serial" tcpip "$PORT"
sleep 2
"$ADB" connect "$address:$PORT"
if ! "$ADB" devices | grep -q "^$address:$PORT[[:space:]]*device"; then
    echo "无线连接失败。确认手机与 Mac 在同一 Wi-Fi、路由器未开 AP 隔离。若 nc -z $address $PORT 能通而 adb 报 No route to host，是旧 adb 服务缺少 macOS 本地网络权限：\"$ADB\" kill-server 后在当前终端重试。" >&2
    exit 1
fi
echo "已切到无线调试：${address}:${PORT}。可拔掉 USB，之后用 DEVICE=$address:$PORT 选择这台手机；手机重启后需重新运行。"
