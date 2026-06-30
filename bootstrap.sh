#!/bin/sh
set -eu

REPO="${REPO:-samsamsue/home_singbox_router}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/home-router-singbox-installer}"
ARCHIVE_URL="${ARCHIVE_URL:-https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz}"
DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-}"

if [ "$(id -u)" != "0" ]; then
  echo "Run as root:" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/${REPO}/${BRANCH}/bootstrap.sh | sudo sh" >&2
  exit 1
fi

ensure_downloader() {
  if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    return
  fi
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl ca-certificates tar
  else
    echo "Missing curl/wget and cannot install dependencies automatically." >&2
    exit 1
  fi
}

download() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$DOWNLOAD_PROXY" ]; then
      curl -fsSL --connect-timeout 15 --max-time 180 -x "$DOWNLOAD_PROXY" -o "$out" "$url"
    else
      curl -fsSL --connect-timeout 15 --max-time 180 -o "$out" "$url"
    fi
  else
    if [ -n "$DOWNLOAD_PROXY" ]; then
      HTTPS_PROXY="$DOWNLOAD_PROXY" HTTP_PROXY="$DOWNLOAD_PROXY" wget -q -O "$out" "$url"
    else
      wget -q -O "$out" "$url"
    fi
  fi
}

ensure_downloader
tmp="$(mktemp -d /tmp/home-router-bootstrap.XXXXXX)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

archive="$tmp/source.tar.gz"
download "$ARCHIVE_URL" "$archive"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
tar -xzf "$archive" -C "$tmp"
src="$(find "$tmp" -mindepth 2 -maxdepth 2 -type f -name install.sh -exec dirname {} \; | head -n 1)"
if [ -z "$src" ]; then
  echo "Downloaded archive layout is unexpected." >&2
  exit 1
fi
cp -R "$src/." "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/install.sh" "$INSTALL_DIR"/scripts/*.sh 2>/dev/null || true

echo "Installer downloaded to $INSTALL_DIR"
cd "$INSTALL_DIR"
exec ./install.sh
