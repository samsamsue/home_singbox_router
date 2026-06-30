#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CONF="${ROUTER_CONF:-$ROOT/router.conf}"
BUILD="$ROOT/build"

if [ "$(id -u)" != "0" ]; then
  echo "Run as root." >&2
  exit 1
fi

tty_read() {
  if [ -r /dev/tty ]; then
    IFS= read -r "$@" </dev/tty
  else
    IFS= read -r "$@"
  fi
}

prompt_value() {
  label="$1"
  default="$2"
  if [ -n "$default" ]; then
    printf "%s [%s]: " "$label" "$default" >/dev/tty 2>/dev/null || printf "%s [%s]: " "$label" "$default" >&2
  else
    printf "%s: " "$label" >/dev/tty 2>/dev/null || printf "%s: " "$label" >&2
  fi
  tty_read value || value=""
  if [ -n "$value" ]; then
    printf "%s" "$value"
  else
    printf "%s" "$default"
  fi
}

prompt_yes_no() {
  label="$1"
  default="${2:-n}"
  if [ "$default" = "y" ]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi
  printf "%s %s: " "$label" "$suffix" >/dev/tty 2>/dev/null || printf "%s %s: " "$label" "$suffix" >&2
  tty_read answer || answer=""
  if [ -z "$answer" ]; then
    answer="$default"
  fi
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

quote_value() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

default_lan_if() {
  ip route show default 2>/dev/null | awk '{ print $5; exit }'
}

default_lan_ip() {
  iface="$1"
  if [ -n "$iface" ]; then
    ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4; exit }'
  fi
}

default_lan_cidr() {
  iface="$1"
  if [ -n "$iface" ]; then
    ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{ print $4; exit }'
  fi
}

cidr_network() {
  cidr="$1"
  python3 - "$cidr" <<'PY' 2>/dev/null || true
import ipaddress
import sys

try:
    print(ipaddress.ip_interface(sys.argv[1]).network)
except Exception:
    pass
PY
}

fallback_lan_net() {
  ipaddr="$1"
  printf "%s\n" "$ipaddr" | awk -F. '
    NF == 4 { print $1 "." $2 "." $3 ".0/24"; ok = 1 }
    END { if (!ok) print "192.168.3.0/24" }
  '
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8
  else
    date +%s | awk '{ print "sb" $1 }'
  fi
}

write_conf() {
  tmp="${CONF}.tmp"
  mkdir -p "$(dirname "$CONF")"
  cat > "$tmp" <<EOF
LAN_IF='$(quote_value "$LAN_IF")'
LAN_NET='$(quote_value "$LAN_NET")'
LAN_IP='$(quote_value "$LAN_IP")'
PROXY_PORT='$(quote_value "$PROXY_PORT")'
PANEL_PORT='$(quote_value "$PANEL_PORT")'
PANEL_SECRET='$(quote_value "$PANEL_SECRET")'
TUN_NAME='$(quote_value "$TUN_NAME")'
TUN_ADDRESS='$(quote_value "$TUN_ADDRESS")'
DNS1='$(quote_value "$DNS1")'
DNS2='$(quote_value "$DNS2")'
SUBSCRIBE_URL='$(quote_value "$SUBSCRIBE_URL")'
SUBSCRIBE_USER_AGENT='$(quote_value "$SUBSCRIBE_USER_AGENT")'
SINGBOX_DEB_URL='$(quote_value "$SINGBOX_DEB_URL")'
DOWNLOAD_PROXY='$(quote_value "$DOWNLOAD_PROXY")'
WEBUI_RELEASE_API='$(quote_value "$WEBUI_RELEASE_API")'
WEBUI_DOWNLOAD_URL='$(quote_value "$WEBUI_DOWNLOAD_URL")'
EOF
  mv "$tmp" "$CONF"
}

create_conf_interactively() {
  if [ ! -r /dev/tty ] && [ "${ASSUME_DEFAULTS:-0}" != "1" ]; then
    echo "Missing router.conf and no interactive terminal is available." >&2
    echo "Run this script directly, or create router.conf from router.conf.example first." >&2
    exit 1
  fi

  echo "No router.conf found. Creating one now." >&2
  echo "Press Enter to keep the value in brackets." >&2
  echo >&2

  detected_if="$(default_lan_if || true)"
  detected_cidr="$(default_lan_cidr "$detected_if" || true)"
  detected_ip="$(default_lan_ip "$detected_if" || true)"
  detected_net="$(cidr_network "$detected_cidr")"
  if [ -z "$detected_net" ]; then
    detected_net="$(fallback_lan_net "${detected_ip:-192.168.3.88}")"
  fi
  default_secret="$(random_secret)"

  LAN_IF="${detected_if:-enp3s0}"
  LAN_IP="${detected_ip:-192.168.3.88}"
  LAN_NET="${detected_net:-192.168.3.0/24}"

  echo "Detected network:" >&2
  echo "  LAN interface: $LAN_IF" >&2
  echo "  Router LAN IP: $LAN_IP" >&2
  echo "  LAN subnet:    $LAN_NET" >&2
  echo >&2
  if prompt_yes_no "Change these network settings?" "n"; then
    LAN_IF="$(prompt_value "LAN interface" "$LAN_IF")"
    LAN_IP="$(prompt_value "Router LAN IP" "$LAN_IP")"
    LAN_NET="$(prompt_value "LAN subnet" "$LAN_NET")"
  fi

  DNS1="223.5.5.5"
  DNS2="119.29.29.29"
  echo "DNS: $DNS1, $DNS2" >&2
  echo >&2

  PROXY_PORT="$(prompt_value "Proxy port" "7890")"
  PANEL_PORT="$(prompt_value "Panel port" "9091")"
  PANEL_SECRET="$(prompt_value "Panel secret" "$default_secret")"

  SUBSCRIBE_URL=""
  while [ -z "$SUBSCRIBE_URL" ] && [ ! -f "$ROOT/secrets/outbounds.json" ]; do
    SUBSCRIBE_URL="$(prompt_value "Clash subscription URL" "")"
    if [ -z "$SUBSCRIBE_URL" ]; then
      echo "Subscription URL is required unless secrets/outbounds.json exists." >&2
    fi
  done

  SUBSCRIBE_USER_AGENT="$(prompt_value "Subscription user-agent" "clash.meta")"
  DOWNLOAD_PROXY="$(prompt_value "Download proxy, optional" "")"
  TUN_NAME="sbtun0"
  TUN_ADDRESS="28.0.0.1/30"
  SINGBOX_DEB_URL="https://github.com/SagerNet/sing-box/releases/download/v1.13.14/sing-box_1.13.14_linux_amd64.deb"
  WEBUI_RELEASE_API="https://api.github.com/repos/MetaCubeX/metacubexd/releases/latest"
  WEBUI_DOWNLOAD_URL="https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"

  write_conf
  chmod 0600 "$CONF" 2>/dev/null || true
  echo >&2
  echo "Created: $CONF" >&2
}

if [ ! -f "$CONF" ]; then
  create_conf_interactively
fi

# shellcheck disable=SC1090
. "$CONF"

LAN_IF="${LAN_IF:-enp3s0}"
LAN_NET="${LAN_NET:-192.168.3.0/24}"
DNS1="${DNS1:-223.5.5.5}"
DNS2="${DNS2:-119.29.29.29}"
SUBSCRIBE_URL="${SUBSCRIBE_URL:-}"
SUBSCRIBE_USER_AGENT="${SUBSCRIBE_USER_AGENT:-clash.meta}"
SINGBOX_DEB_URL="${SINGBOX_DEB_URL:-https://github.com/SagerNet/sing-box/releases/download/v1.13.14/sing-box_1.13.14_linux_amd64.deb}"
DOWNLOAD_PROXY="${DOWNLOAD_PROXY:-}"
WEBUI_RELEASE_API="${WEBUI_RELEASE_API:-https://api.github.com/repos/MetaCubeX/metacubexd/releases/latest}"
WEBUI_DOWNLOAD_URL="${WEBUI_DOWNLOAD_URL:-https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz}"

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

ensure_python_yaml() {
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    return
  fi
  apt-get update
  apt-get install -y python3-yaml
}

install_singbox
mkdir -p "$BUILD" /etc/home-router-singbox /etc/sing-box /usr/local/sbin /usr/local/bin /usr/local/share/metacubexd /opt/home-router-singbox

cp "$CONF" /etc/home-router-singbox/router.conf
cp -a "$ROOT/scripts" "$ROOT/templates" /opt/home-router-singbox/

ensure_python_yaml
if [ -n "$SUBSCRIBE_URL" ]; then
  ROUTER_CONF=/etc/home-router-singbox/router.conf \
  OUTBOUNDS_JSON=/etc/home-router-singbox/outbounds.json \
  SUBSCRIPTION_CACHE=/etc/home-router-singbox/subscription.yaml \
    /opt/home-router-singbox/scripts/update-subscription.sh
elif [ -f "$ROOT/secrets/outbounds.json" ]; then
  cp "$ROOT/secrets/outbounds.json" /etc/home-router-singbox/outbounds.json
else
  echo "Missing proxy nodes. Set SUBSCRIBE_URL in router.conf or create secrets/outbounds.json." >&2
  exit 1
fi

ROUTER_CONF=/etc/home-router-singbox/router.conf \
OUTBOUNDS_JSON=/etc/home-router-singbox/outbounds.json \
OUTPUT="$BUILD/config.json" \
  python3 "$ROOT/scripts/render-config.py"
cp "$BUILD/config.json" /etc/sing-box/config.json

if [ -d "$ROOT/webui" ]; then
  rm -rf /usr/local/share/metacubexd/*
  cp -a "$ROOT/webui/." /usr/local/share/metacubexd/
fi

cp "$ROOT/scripts/home-lan-bypass-forward.sh" /usr/local/sbin/home-lan-bypass-forward.sh
chmod 0755 /usr/local/sbin/home-lan-bypass-forward.sh
cp "$ROOT/scripts/update-subscription.sh" /usr/local/sbin/home-router-update-subscription.sh
chmod 0755 /usr/local/sbin/home-router-update-subscription.sh
cp "$ROOT/scripts/update-webui.sh" /usr/local/sbin/home-router-update-webui.sh
chmod 0755 /usr/local/sbin/home-router-update-webui.sh
cp "$ROOT/scripts/uninstall.sh" /usr/local/sbin/home-router-uninstall.sh
chmod 0755 /usr/local/sbin/home-router-uninstall.sh
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
