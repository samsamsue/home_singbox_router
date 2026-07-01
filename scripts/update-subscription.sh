#!/bin/sh
set -eu

APP_DIR="${APP_DIR:-/opt/bypassproxy}"
CONF="${ROUTER_CONF:-/etc/bypassproxy/router.conf}"
OUTBOUNDS_JSON="${OUTBOUNDS_JSON:-/etc/bypassproxy/outbounds.json}"
SUBSCRIPTION_CACHE="${SUBSCRIPTION_CACHE:-/etc/bypassproxy/subscription.yaml}"
SUBSCRIPTION_CACHE_DIR="${SUBSCRIPTION_CACHE_DIR:-/etc/bypassproxy/subscriptions.d}"

if [ ! -f "$CONF" ]; then
  echo "缺少配置文件：$CONF" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$CONF"

SUBSCRIBE_URL="${SUBSCRIBE_URL:-}"
SUBSCRIBE_URLS="${SUBSCRIBE_URLS:-}"
SUBSCRIBE_USER_AGENT="${SUBSCRIBE_USER_AGENT:-clash.meta}"
DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-}"

if [ -z "$SUBSCRIBE_URL" ] && [ -z "$SUBSCRIBE_URLS" ]; then
  echo "订阅/节点地址为空。请运行 sudo bp 修改配置，或编辑 router.conf。" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTBOUNDS_JSON")" "$SUBSCRIPTION_CACHE_DIR"
rm -f "$SUBSCRIPTION_CACHE_DIR"/*

download() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$DOWNLOAD_PROXY" ]; then
      curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 -A "$SUBSCRIBE_USER_AGENT" -x "$DOWNLOAD_PROXY" -o "$out" "$url"
    else
      curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 -A "$SUBSCRIBE_USER_AGENT" -o "$out" "$url"
    fi
  else
    wget -q -U "$SUBSCRIBE_USER_AGENT" -O "$out" "$url"
  fi
}

count=0
for source in $SUBSCRIBE_URL $SUBSCRIBE_URLS; do
  count=$((count + 1))
  cache="$SUBSCRIPTION_CACHE_DIR/source-${count}.txt"
  case "$source" in
    vmess://*)
      printf "%s\n" "$source" > "$cache"
      ;;
    *)
      download "$source" "$cache"
      ;;
  esac
done

if [ "$count" -eq 1 ] && [ -f "$SUBSCRIPTION_CACHE_DIR/source-1.txt" ]; then
  cp "$SUBSCRIPTION_CACHE_DIR/source-1.txt" "$SUBSCRIPTION_CACHE"
fi

python3 "$APP_DIR/scripts/extract-outbounds.py" "$SUBSCRIPTION_CACHE_DIR" "$OUTBOUNDS_JSON"
echo "订阅已更新：$OUTBOUNDS_JSON"
