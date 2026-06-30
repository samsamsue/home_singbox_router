#!/bin/sh
set -eu

case "${1:-}" in
  status)
    systemctl --no-pager --full status sing-box
    ;;
  restart)
    sing-box check -C /etc/sing-box
    systemctl restart sing-box
    ;;
  logs)
    journalctl -u sing-box -f
    ;;
  check)
    sing-box check -C /etc/sing-box
    ;;
  apply-forward)
    /usr/local/sbin/home-lan-bypass-forward.sh
    ;;
  update-webui)
    /usr/local/sbin/home-router-update-webui.sh
    ;;
  uninstall)
    /usr/local/sbin/home-router-uninstall.sh
    ;;
  *)
    echo "usage: $0 {status|restart|logs|check|apply-forward|update-webui|uninstall}" >&2
    exit 2
    ;;
esac
