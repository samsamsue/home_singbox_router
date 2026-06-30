#!/bin/sh
set -eu

REPO="${REPO:-samsamsue/home_singbox_router}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/home-router-singbox-installer}"
ARCHIVE_URL="${ARCHIVE_URL:-https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz}"
DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-}"
GITHUB_DOWNLOAD_PREFIX="${GITHUB_DOWNLOAD_PREFIX:-}"

if [ "$(id -u)" != "0" ]; then
  echo "请用 root 运行：" >&2
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
    echo "缺少 curl/wget，且无法自动安装依赖。" >&2
    exit 1
  fi
}

download() {
  url="$1"
  out="$2"
  case "$url" in
    https://github.com/*|https://raw.githubusercontent.com/*)
      if [ -n "$GITHUB_DOWNLOAD_PREFIX" ]; then
        url="${GITHUB_DOWNLOAD_PREFIX}${url}"
      fi
      ;;
  esac
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$DOWNLOAD_PROXY" ]; then
      curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 -x "$DOWNLOAD_PROXY" -o "$out" "$url"
    else
      curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 -o "$out" "$url"
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
  echo "下载的安装包结构不符合预期。" >&2
  exit 1
fi
cp -R "$src/." "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/install.sh" "$INSTALL_DIR"/scripts/*.sh 2>/dev/null || true

echo "安装器已下载到 $INSTALL_DIR"
cd "$INSTALL_DIR"
exec ./install.sh
