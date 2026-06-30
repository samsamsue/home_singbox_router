#!/bin/sh
set -eu

CONF="${ROUTER_CONF:-/etc/home-router-singbox/router.conf}"
BACKUP_ROOT="${BACKUP_ROOT:-/root}"

if [ "$(id -u)" != "0" ]; then
  echo "Run as root: sudo home-router-uninstall.sh" >&2
  exit 1
fi

if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi

LAN_IF="${LAN_IF:-enp3s0}"
LAN_NET="${LAN_NET:-192.168.3.0/24}"

confirm_uninstall() {
  if [ "${ASSUME_YES:-0}" = "1" ] || [ "${1:-}" = "--yes" ]; then
    return
  fi

  cat <<EOF
This will uninstall Home Router sing-box and remove:
  - sb/sc menu commands
  - home-router systemd forwarding service/timer
  - /etc/home-router-singbox
  - /etc/sing-box
  - /opt/home-router-singbox
  - /usr/local/share/metacubexd
  - forwarding/NAT rules created for ${LAN_IF} ${LAN_NET}

A backup will be created first under ${BACKUP_ROOT}.
Type UNINSTALL to continue:
EOF
  read answer || answer=""
  if [ "$answer" != "UNINSTALL" ]; then
    echo "Cancelled."
    exit 0
  fi

  printf "Also purge the sing-box package? [y/N]: "
  read purge_answer || purge_answer=""
  case "$purge_answer" in
    y|Y|yes|YES) PURGE_SINGBOX=1 ;;
    *) PURGE_SINGBOX="${PURGE_SINGBOX:-0}" ;;
  esac
  export PURGE_SINGBOX
}

backup_existing_files() {
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${BACKUP_ROOT}/home-router-singbox-uninstall-backup-${stamp}.tar.gz"
  list="/tmp/home-router-singbox-uninstall-backup.$$"
  : > "$list"

  for path in \
    /etc/home-router-singbox \
    /etc/sing-box \
    /opt/home-router-singbox \
    /usr/local/share/metacubexd \
    /etc/systemd/system/home-lan-bypass-forward.service \
    /etc/systemd/system/home-lan-bypass-forward.timer \
    /etc/sysctl.d/99-home-lan-bypass-forward.conf \
    /usr/local/sbin/home-lan-bypass-forward.sh \
    /usr/local/sbin/home-router-update-subscription.sh \
    /usr/local/sbin/home-router-update-webui.sh \
    /usr/local/sbin/home-router-uninstall.sh \
    /usr/local/bin/sb \
    /usr/local/bin/sc
  do
    if [ -e "$path" ] || [ -L "$path" ]; then
      printf "%s\n" "${path#/}" >> "$list"
    fi
  done

  if [ -s "$list" ]; then
    mkdir -p "$BACKUP_ROOT"
    tar -C / -czf "$backup" -T "$list"
    echo "Backup: $backup"
  else
    echo "Nothing to back up."
  fi

  rm -f "$list"
}

remove_filter_rule() {
  while iptables -C "$@" 2>/dev/null; do
    iptables -D "$@" 2>/dev/null || break
  done
}

remove_table_rule() {
  table="$1"
  shift
  while iptables -t "$table" -C "$@" 2>/dev/null; do
    iptables -t "$table" -D "$@" 2>/dev/null || break
  done
}

stop_services() {
  systemctl disable --now home-lan-bypass-forward.timer 2>/dev/null || true
  systemctl disable --now home-lan-bypass-forward.service 2>/dev/null || true
  systemctl disable --now sing-box 2>/dev/null || true
  pkill -f 'sing-box' 2>/dev/null || true
}

remove_firewall_rules() {
  remove_filter_rule FORWARD -i "$LAN_IF" -o "$LAN_IF" -s "$LAN_NET" -j ACCEPT
  remove_table_rule nat POSTROUTING -s "$LAN_NET" -o "$LAN_IF" -j MASQUERADE

  # Removed for compatibility with older versions of this kit.
  remove_table_rule mangle PREROUTING -i "$LAN_IF" -s "$LAN_NET" -p udp --dport 443 -j RETURN
}

remove_files() {
  rm -f \
    /etc/systemd/system/home-lan-bypass-forward.service \
    /etc/systemd/system/home-lan-bypass-forward.timer \
    /etc/sysctl.d/99-home-lan-bypass-forward.conf \
    /usr/local/sbin/home-lan-bypass-forward.sh \
    /usr/local/sbin/home-router-update-subscription.sh \
    /usr/local/sbin/home-router-update-webui.sh \
    /usr/local/bin/sb \
    /usr/local/bin/sc

  rm -rf \
    /etc/home-router-singbox \
    /etc/sing-box \
    /opt/home-router-singbox \
    /usr/local/share/metacubexd

  systemctl daemon-reload 2>/dev/null || true
}

restore_resolv_conf() {
  if [ "${RESTORE_RESOLV_CONF:-1}" = "1" ]; then
    cat > /etc/resolv.conf <<DNS
nameserver 223.5.5.5
nameserver 119.29.29.29
options timeout:2 attempts:2
DNS
  fi
}

purge_singbox_package() {
  if [ "${PURGE_SINGBOX:-0}" = "1" ]; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get purge -y sing-box || true
      apt-get autoremove -y || true
    elif command -v dpkg >/dev/null 2>&1; then
      dpkg -P sing-box || true
    fi
  fi
}

confirm_uninstall "${1:-}"
backup_existing_files
stop_services
remove_firewall_rules
remove_files
restore_resolv_conf
purge_singbox_package
rm -f /usr/local/sbin/home-router-uninstall.sh

echo "Uninstalled Home Router sing-box."
echo "If you used it as a phone gateway, change the phone gateway/DNS back to your main router."
