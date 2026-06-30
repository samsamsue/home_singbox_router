#!/bin/sh
set -eu

CONF="${ROUTER_CONF:-/etc/home-router-singbox/router.conf}"
WEBUI_DIR="${WEBUI_DIR:-/usr/local/share/metacubexd}"
WEBUI_RELEASE_API="${WEBUI_RELEASE_API:-https://api.github.com/repos/MetaCubeX/metacubexd/releases/latest}"
WEBUI_DOWNLOAD_URL="${WEBUI_DOWNLOAD_URL:-https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz}"
DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-}"
GITHUB_DOWNLOAD_PREFIX="${GITHUB_DOWNLOAD_PREFIX:-}"

if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi

WEBUI_DIR="${WEBUI_DIR:-/usr/local/share/metacubexd}"
WEBUI_RELEASE_API="${WEBUI_RELEASE_API:-https://api.github.com/repos/MetaCubeX/metacubexd/releases/latest}"
WEBUI_DOWNLOAD_URL="${WEBUI_DOWNLOAD_URL:-https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz}"
DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-}"
GITHUB_DOWNLOAD_PREFIX="${GITHUB_DOWNLOAD_PREFIX:-}"

download_url() {
  url="$1"
  case "$url" in
    https://github.com/*|https://raw.githubusercontent.com/*)
      if [ -n "$GITHUB_DOWNLOAD_PREFIX" ]; then
        printf "%s%s" "$GITHUB_DOWNLOAD_PREFIX" "$url"
        return
      fi
      ;;
  esac
  printf "%s" "$url"
}

download() {
  url="$1"
  out="$2"
  real_url="$(download_url "$url")"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$DOWNLOAD_PROXY" ]; then
      curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 -x "$DOWNLOAD_PROXY" -o "$out" "$real_url"
    else
      curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 -o "$out" "$real_url"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [ -n "$DOWNLOAD_PROXY" ]; then
      HTTPS_PROXY="$DOWNLOAD_PROXY" HTTP_PROXY="$DOWNLOAD_PROXY" wget -q -O "$out" "$real_url"
    else
      wget -q -O "$out" "$real_url"
    fi
  else
    echo "Missing curl or wget." >&2
    exit 1
  fi
}

effective_url() {
  url="$1"
  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi
  if [ -n "$DOWNLOAD_PROXY" ]; then
    curl -fsSLI --connect-timeout 15 -x "$DOWNLOAD_PROXY" -o /dev/null -w "%{url_effective}" "$url"
  else
    curl -fsSLI --connect-timeout 15 -o /dev/null -w "%{url_effective}" "$url"
  fi
}

json_value() {
  key="$1"
  file="$2"
  python3 - "$key" "$file" <<'PY'
import json
import sys

key, path = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(key, "")
if value is None:
    value = ""
print(value)
PY
}

asset_url() {
  file="$1"
  python3 - "$file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
for asset in data.get("assets", []):
    if asset.get("name") == "compressed-dist.tgz":
        print(asset.get("browser_download_url", ""))
        break
PY
}

tmp="$(mktemp -d /tmp/home-router-webui.XXXXXX)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

latest_tag=""
api_json="$tmp/latest.json"
if command -v python3 >/dev/null 2>&1 && download "$WEBUI_RELEASE_API" "$api_json" 2>/dev/null; then
  latest_tag="$(json_value tag_name "$api_json" 2>/dev/null || true)"
  release_asset="$(asset_url "$api_json" 2>/dev/null || true)"
  if [ -n "$release_asset" ]; then
    WEBUI_DOWNLOAD_URL="$release_asset"
  fi
fi

if [ -z "$latest_tag" ]; then
  resolved="$(effective_url "https://github.com/MetaCubeX/metacubexd/releases/latest" 2>/dev/null || true)"
  latest_tag="$(printf "%s" "$resolved" | sed -n 's#.*/tag/\([^/?#]*\).*#\1#p')"
fi

current_tag=""
if [ -f "$WEBUI_DIR/.home-router-webui-version" ]; then
  current_tag="$(cat "$WEBUI_DIR/.home-router-webui-version" 2>/dev/null || true)"
fi

if [ -n "$latest_tag" ] && [ "$latest_tag" = "$current_tag" ] && [ "${FORCE_WEBUI_UPDATE:-0}" != "1" ]; then
  echo "MetaCubeXD WebUI is already latest: $latest_tag"
  exit 0
fi

archive="$tmp/compressed-dist.tgz"
extract_dir="$tmp/extract"
install_dir="$tmp/install"
mkdir -p "$extract_dir" "$install_dir"

echo "Downloading MetaCubeXD WebUI..."
download "$WEBUI_DOWNLOAD_URL" "$archive"
tar -xzf "$archive" -C "$extract_dir"

if [ -f "$extract_dir/dist/index.html" ]; then
  src="$extract_dir/dist"
elif [ -f "$extract_dir/index.html" ]; then
  src="$extract_dir"
else
  src="$(find "$extract_dir" -mindepth 1 -maxdepth 2 -type f -name index.html -exec dirname {} \; | head -n 1)"
  if [ -z "$src" ]; then
    echo "Downloaded WebUI package does not contain index.html." >&2
    exit 1
  fi
fi

cp -R "$src/." "$install_dir/"
if [ -n "$latest_tag" ]; then
  printf "%s\n" "$latest_tag" > "$install_dir/.home-router-webui-version"
fi
chmod -R a+rX "$install_dir"

backup=""
if [ -d "$WEBUI_DIR" ] && [ "$(find "$WEBUI_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${WEBUI_DIR}.backup-${stamp}"
  mv "$WEBUI_DIR" "$backup"
fi

mkdir -p "$WEBUI_DIR"
cp -R "$install_dir/." "$WEBUI_DIR/"
chown -R root:root "$WEBUI_DIR" 2>/dev/null || true
chmod -R a+rX "$WEBUI_DIR"

if [ -n "$backup" ]; then
  rm -rf "$backup"
fi

if [ -n "$latest_tag" ]; then
  echo "Updated MetaCubeXD WebUI to $latest_tag."
else
  echo "Updated MetaCubeXD WebUI."
fi
