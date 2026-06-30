#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CONF="${ROUTER_CONF:-$ROOT/router.conf}"
BUILD="$ROOT/build"

if [ "$(id -u)" != "0" ]; then
  echo "Run as root." >&2
  exit 1
fi

if [ ! -f "$CONF" ]; then
  echo "Missing router.conf. Copy router.conf.example to router.conf and edit it." >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$CONF"

LAN_IF="${LAN_IF:-enp3s0}"
LAN_NET="${LAN_NET:-192.168.3.0/24}"
DNS1="${DNS1:-223.5.5.5}"
DNS2="${DNS2:-119.29.29.29}"
SINGBOX_DEB_URL="${SINGBOX_DEB_URL:-https://github.com/SagerNet/sing-box/releases/download/v1.13.14/sing-box_1.13.14_linux_amd64.deb}"
DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-}"

download() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$DOWNLOAD_PROXY" ]; then
      curl -L --connect-timeout 15 --max-time 180 -x "$DOWNLOAD_PROXY" -o "$out" "$url"
    else
      curl -L --connect-timeout 15 --max-time 180 -o "$out" "$url"
    fi
  else
    wget -O "$out" "$url"
  fi
}

install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    return
  fi
  tmp="/tmp/sing-box.deb"
  download "$SINGBOX_DEB_URL" "$tmp"
  dpkg -i "$tmp"
}

install_singbox
mkdir -p "$BUILD" /etc/home-router-singbox /etc/sing-box /usr/local/sbin /usr/local/bin /usr/local/share/metacubexd /opt/home-router-singbox

cp "$CONF" /etc/home-router-singbox/router.conf
python3 "$ROOT/scripts/render-config.py"
cp "$BUILD/config.json" /etc/sing-box/config.json
cp -a "$ROOT/scripts" "$ROOT/templates" /opt/home-router-singbox/

if [ -d "$ROOT/webui" ]; then
  rm -rf /usr/local/share/metacubexd/*
  cp -a "$ROOT/webui/." /usr/local/share/metacubexd/
fi

cp "$ROOT/scripts/home-lan-bypass-forward.sh" /usr/local/sbin/home-lan-bypass-forward.sh
chmod 0755 /usr/local/sbin/home-lan-bypass-forward.sh
cp "$ROOT/scripts/sc-menu.sh" /usr/local/bin/sb
chmod 0755 /usr/local/bin/sb
ln -sf /usr/local/bin/sb /usr/local/bin/sc

cat > /etc/sysctl.d/99-home-lan-bypass-forward.conf <<SYSCTL
net.ipv4.ip_forward=1
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.${LAN_IF}.send_redirects=0
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.${LAN_IF}.rp_filter=0
SYSCTL

cat > /etc/systemd/system/home-lan-bypass-forward.service <<SERVICE
[Unit]
Description=Allow same-interface LAN forwarding for home bypass router
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=ROUTER_CONF=/etc/home-router-singbox/router.conf
ExecStart=/usr/local/sbin/home-lan-bypass-forward.sh

[Install]
WantedBy=multi-user.target
SERVICE

cat > /etc/systemd/system/home-lan-bypass-forward.timer <<TIMER
[Unit]
Description=Refresh home bypass router forwarding rules

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
AccuracySec=10s
Unit=home-lan-bypass-forward.service

[Install]
WantedBy=timers.target
TIMER

systemctl disable --now shellcrash.service 2>/dev/null || true
pkill -f '/tmp/ShellCrash/CrashCore' 2>/dev/null || true

cat > /etc/resolv.conf <<DNS
nameserver ${DNS1}
nameserver ${DNS2}
options timeout:2 attempts:2
DNS

sing-box check -C /etc/sing-box
systemctl daemon-reload
systemctl enable --now sing-box
systemctl enable --now home-lan-bypass-forward.timer
/usr/local/sbin/home-lan-bypass-forward.sh

echo "Installed."
echo "Panel: http://${LAN_IP}:${PANEL_PORT}/ui/"
echo "Proxy: http://${LAN_IP}:${PROXY_PORT}"
echo "Menu: sudo sb"
