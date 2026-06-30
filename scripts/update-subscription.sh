#!/bin/sh
set -eu

APP_DIR="${APP_DIR:-/opt/home-router-singbox}"
CONF="${ROUTER_CONF:-/etc/home-router-singbox/router.conf}"
OUTBOUNDS_JSON="${OUTBOUNDS_JSON:-/etc/home-router-singbox/outbounds.json}"
SUBSCRIPTION_CACHE="${SUBSCRIPTION_CACHE:-/etc/home-router-singbox/subscription.yaml}"

if [ ! -f "$CONF" ]; then
  echo "Missing config: $CONF" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$CONF"

SUBSCRIBE_URL="${SUBSCRIBE_URL:-}"
SUBSCRIBE_USER_AGENT="${SUBSCRIBE_USER_AGENT:-clash.meta}"
DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-}"

if [ -z "$SUBSCRIBE_URL" ]; then
  echo "SUBSCRIBE_URL is empty. Edit router.conf or run sudo sb." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTBOUNDS_JSON")" "$(dirname "$SUBSCRIPTION_CACHE")"

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

download "$SUBSCRIBE_URL" "$SUBSCRIPTION_CACHE"
python3 "$APP_DIR/scripts/extract-outbounds.py" "$SUBSCRIPTION_CACHE" "$OUTBOUNDS_JSON"
echo "Updated $OUTBOUNDS_JSON"
