#!/bin/sh
set -eu

APP_DIR="${APP_DIR:-/opt/home-router-singbox}"
CONF="${ROUTER_CONF:-/etc/home-router-singbox/router.conf}"
CONFIG_JSON="/etc/sing-box/config.json"

pause() {
  printf "\nPress Enter to continue..."
  # shellcheck disable=SC2034
  read _ || true
}

need_root() {
  if [ "$(id -u)" != "0" ]; then
    echo "Please run as root: sudo sb" >&2
    exit 1
  fi
}

load_conf() {
  if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
  fi
  LAN_IF="${LAN_IF:-enp3s0}"
  LAN_NET="${LAN_NET:-192.168.3.0/24}"
  LAN_IP="${LAN_IP:-192.168.3.88}"
  PROXY_PORT="${PROXY_PORT:-7890}"
  PANEL_PORT="${PANEL_PORT:-9091}"
  PANEL_SECRET="${PANEL_SECRET:-}"
  DNS1="${DNS1:-223.5.5.5}"
  DNS2="${DNS2:-119.29.29.29}"
  SUBSCRIBE_URL="${SUBSCRIBE_URL:-}"
  SUBSCRIBE_USER_AGENT="${SUBSCRIBE_USER_AGENT:-clash.meta}"
}

detect_zt_ip() {
  ip -4 -o addr show 2>/dev/null \
    | awk '$2 ~ /^zt/ { sub(/\/.*/, "", $4); print $4; exit }'
}

save_key() {
  key="$1"
  value="$2"
  mkdir -p "$(dirname "$CONF")"
  touch "$CONF"
  quoted=$(printf "%s" "$value" | sed "s/'/'\\\\''/g")
  newline="${key}='${quoted}'"
  tmp="${CONF}.tmp"
  awk -v key="$key" -v newline="$newline" '
    BEGIN { found = 0 }
    index($0, key "=") == 1 { print newline; found = 1; next }
    { print }
    END { if (!found) print newline }
  ' "$CONF" > "$tmp"
  mv "$tmp" "$CONF"
}

prompt_key() {
  key="$1"
  label="$2"
  current="$3"
  printf "%s [%s]: " "$label" "$current"
  read value || value=""
  if [ -n "$value" ]; then
    save_key "$key" "$value"
  fi
}

apply_config() {
  if [ ! -x "$APP_DIR/scripts/render-config.py" ]; then
    echo "Missing renderer: $APP_DIR/scripts/render-config.py" >&2
    return 1
  fi
  ROUTER_CONF="$CONF" OUTBOUNDS_JSON=/etc/home-router-singbox/outbounds.json OUTPUT="$CONFIG_JSON" python3 "$APP_DIR/scripts/render-config.py"
  sing-box check -C /etc/sing-box
  systemctl restart sing-box
  systemctl restart home-lan-bypass-forward.timer 2>/dev/null || true
  /usr/local/sbin/home-lan-bypass-forward.sh 2>/dev/null || true
}

update_subscription() {
  if [ ! -x /usr/local/sbin/home-router-update-subscription.sh ]; then
    echo "Missing updater: /usr/local/sbin/home-router-update-subscription.sh" >&2
    return 1
  fi
  ROUTER_CONF="$CONF" /usr/local/sbin/home-router-update-subscription.sh
  apply_config
}

update_webui() {
  if [ ! -x /usr/local/sbin/home-router-update-webui.sh ]; then
    echo "Missing updater: /usr/local/sbin/home-router-update-webui.sh" >&2
    return 1
  fi
  ROUTER_CONF="$CONF" /usr/local/sbin/home-router-update-webui.sh
}

uninstall_router() {
  if [ ! -x /usr/local/sbin/home-router-uninstall.sh ]; then
    echo "Missing uninstaller: /usr/local/sbin/home-router-uninstall.sh" >&2
    return 1
  fi
  /usr/local/sbin/home-router-uninstall.sh
}

show_status() {
  load_conf
  echo "sing-box: $(systemctl is-active sing-box 2>/dev/null || true)"
  echo "ShellCrash: $(systemctl is-active shellcrash.service 2>/dev/null || true)"
  echo
  echo "Panel: http://${LAN_IP}:${PANEL_PORT}/ui/"
  echo "Backend: http://${LAN_IP}:${PANEL_PORT}"
  echo "Secret: ${PANEL_SECRET}"
  echo "Proxy: http://${LAN_IP}:${PROXY_PORT}"
  zt_ip="$(detect_zt_ip || true)"
  if [ -n "$zt_ip" ]; then
    echo
    echo "ZeroTier panel: http://${zt_ip}:${PANEL_PORT}/ui/"
    echo "ZeroTier proxy: http://${zt_ip}:${PROXY_PORT}"
  fi
  echo
  echo "Phone at home:"
  echo "  Gateway: ${LAN_IP}"
  echo "  DNS: ${DNS1} or ${DNS2}"
  if [ -n "$SUBSCRIBE_URL" ]; then
    echo
    echo "Subscription: configured"
  fi
  echo
  ss -lntup 2>/dev/null | grep -E ":${PROXY_PORT}|:${PANEL_PORT}" || true
}

edit_basic() {
  load_conf
  echo "Leave blank to keep the current value."
  prompt_key LAN_IF "LAN interface" "$LAN_IF"
  prompt_key LAN_NET "LAN subnet" "$LAN_NET"
  prompt_key LAN_IP "Router LAN IP" "$LAN_IP"
  prompt_key PROXY_PORT "Proxy port" "$PROXY_PORT"
  prompt_key PANEL_PORT "Panel port" "$PANEL_PORT"
  prompt_key PANEL_SECRET "Panel secret" "$PANEL_SECRET"
  prompt_key DNS1 "DNS 1" "$DNS1"
  prompt_key DNS2 "DNS 2" "$DNS2"
  prompt_key SUBSCRIBE_URL "Clash subscription URL" "$SUBSCRIBE_URL"
  prompt_key SUBSCRIBE_USER_AGENT "Subscription user-agent" "$SUBSCRIBE_USER_AGENT"
  echo
  echo "Applying..."
  load_conf
  if [ -n "${SUBSCRIBE_URL:-}" ]; then
    update_subscription
  else
    apply_config
  fi
}

open_info() {
  load_conf
  zt_ip="$(detect_zt_ip || true)"
  cat <<EOF
Open this in your browser:
  LAN: http://${LAN_IP}:${PANEL_PORT}/ui/
$(if [ -n "$zt_ip" ]; then printf "  ZeroTier: http://%s:%s/ui/\n" "$zt_ip" "$PANEL_PORT"; fi)

When MetaCubeXD asks for backend:
  Backend LAN: http://${LAN_IP}:${PANEL_PORT}
$(if [ -n "$zt_ip" ]; then printf "  Backend ZeroTier: http://%s:%s\n" "$zt_ip" "$PANEL_PORT"; fi)
  Secret:  ${PANEL_SECRET}

Explicit proxy:
  LAN: http://${LAN_IP}:${PROXY_PORT}
$(if [ -n "$zt_ip" ]; then printf "  ZeroTier: http://%s:%s\n" "$zt_ip" "$PROXY_PORT"; fi)
EOF
}

main_menu() {
  need_root
  while true; do
    clear 2>/dev/null || true
    load_conf
    cat <<EOF
Home sing-box router (sb)
====================
1) Status
2) Restart sing-box
3) Show logs
4) Panel/proxy info
5) Edit basic settings (prompt input)
6) Update subscription
7) Update WebUI panel
8) Check config
9) Apply forwarding/NAT rules
10) Uninstall cleanly
11) Quit

EOF
    printf "Select: "
    read choice || exit 0
    case "$choice" in
      1) show_status; pause ;;
      2) apply_config; echo "Restarted."; pause ;;
      3) journalctl -u sing-box -f ;;
      4) open_info; pause ;;
      5) edit_basic; pause ;;
      6) update_subscription; pause ;;
      7) update_webui; pause ;;
      8) sing-box check -C /etc/sing-box; pause ;;
      9) /usr/local/sbin/home-lan-bypass-forward.sh; echo "Applied."; pause ;;
      10) uninstall_router; exit 0 ;;
      11|q|Q) exit 0 ;;
      *) echo "Invalid choice."; pause ;;
    esac
  done
}

main_menu
