#!/bin/sh
set -eu

APP_DIR="${APP_DIR:-/opt/bypassproxy}"
CONF="${ROUTER_CONF:-/etc/bypassproxy/router.conf}"
CONFIG_JSON="/etc/sing-box/config.json"

pause() {
  printf "\n按回车继续..."
  # shellcheck disable=SC2034
  read _ || true
}

need_root() {
  if [ "$(id -u)" != "0" ]; then
    echo "请用 root 运行：sudo bp" >&2
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
  SUBSCRIBE_URLS="${SUBSCRIBE_URLS:-}"
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

secret_status() {
  if [ -n "${PANEL_SECRET:-}" ]; then
    printf "已设置"
  else
    printf "未设置"
  fi
}

update_rulesets() {
  if [ -x /usr/local/sbin/bypassproxy-update-rulesets.sh ]; then
    ROUTER_CONF="$CONF" RULE_DIR=/etc/bypassproxy/rules /usr/local/sbin/bypassproxy-update-rulesets.sh
    return
  fi
  if [ -x "$APP_DIR/scripts/update-rulesets.sh" ]; then
    ROUTER_CONF="$CONF" RULE_DIR=/etc/bypassproxy/rules "$APP_DIR/scripts/update-rulesets.sh"
    return
  fi
  echo "缺少分流规则更新脚本。" >&2
  return 1
}

apply_config() {
  if [ ! -x "$APP_DIR/scripts/render-config.py" ]; then
    echo "缺少配置生成器：$APP_DIR/scripts/render-config.py" >&2
    return 1
  fi
  update_rulesets
  ROUTER_CONF="$CONF" OUTBOUNDS_JSON=/etc/bypassproxy/outbounds.json OUTPUT="$CONFIG_JSON" python3 "$APP_DIR/scripts/render-config.py"
  sing-box check -C /etc/sing-box
  systemctl restart sing-box
  systemctl restart bypassproxy-forward.timer 2>/dev/null || true
  /usr/local/sbin/bypassproxy-forward.sh 2>/dev/null || true
}

check_config() {
  echo "正在检查 sing-box 配置..."
  if sing-box check -C /etc/sing-box; then
    echo "配置检查通过。"
    return 0
  fi
  echo "配置检查失败，请查看上面的错误信息。" >&2
  return 1
}

update_subscription() {
  if [ ! -x /usr/local/sbin/bypassproxy-update-subscription.sh ]; then
    echo "缺少订阅更新脚本：/usr/local/sbin/bypassproxy-update-subscription.sh" >&2
    return 1
  fi
  ROUTER_CONF="$CONF" /usr/local/sbin/bypassproxy-update-subscription.sh
  apply_config
}

update_webui() {
  if [ ! -x /usr/local/sbin/bypassproxy-update-webui.sh ]; then
    echo "缺少 Web 面板更新脚本：/usr/local/sbin/bypassproxy-update-webui.sh" >&2
    return 1
  fi
  ROUTER_CONF="$CONF" /usr/local/sbin/bypassproxy-update-webui.sh
}

update_core() {
  if [ -x /usr/local/sbin/bypassproxy-update-core.sh ]; then
    ROUTER_CONF="$CONF" /usr/local/sbin/bypassproxy-update-core.sh
    return
  fi
  if [ -x "$APP_DIR/scripts/update-core.sh" ]; then
    ROUTER_CONF="$CONF" "$APP_DIR/scripts/update-core.sh"
    return
  fi
  echo "缺少项目更新脚本。" >&2
  return 1
}

diagnose_network() {
  if [ -x /usr/local/sbin/bypassproxy-diagnose-network.sh ]; then
    ROUTER_CONF="$CONF" /usr/local/sbin/bypassproxy-diagnose-network.sh
    return
  fi
  if [ -x "$APP_DIR/scripts/diagnose-network.sh" ]; then
    ROUTER_CONF="$CONF" "$APP_DIR/scripts/diagnose-network.sh"
    return
  fi
  echo "缺少网络诊断脚本。" >&2
  return 1
}

uninstall_router() {
  if [ ! -x /usr/local/sbin/bypassproxy-uninstall.sh ]; then
    echo "缺少卸载脚本：/usr/local/sbin/bypassproxy-uninstall.sh" >&2
    return 1
  fi
  /usr/local/sbin/bypassproxy-uninstall.sh
}

show_status() {
  load_conf
  echo "sing-box 状态：$(systemctl is-active sing-box 2>/dev/null || true)"
  echo "ShellCrash：$(systemctl is-active shellcrash.service 2>/dev/null || true)"
  echo
  echo "面板地址：http://${LAN_IP}:${PANEL_PORT}/ui/"
  echo "面板后端：http://${LAN_IP}:${PANEL_PORT}"
  echo "面板密钥：$(secret_status)"
  echo "显式代理：http://${LAN_IP}:${PROXY_PORT}"
  zt_ip="$(detect_zt_ip || true)"
  if [ -n "$zt_ip" ]; then
    echo
    echo "ZeroTier 面板：http://${zt_ip}:${PANEL_PORT}/ui/"
    echo "ZeroTier 代理：http://${zt_ip}:${PROXY_PORT}"
  fi
  echo
  echo "家里手机设置："
  echo "  网关：${LAN_IP}"
  echo "  DNS：${DNS1} 或 ${DNS2}"
  if [ -n "$SUBSCRIBE_URL" ] || [ -n "$SUBSCRIBE_URLS" ]; then
    echo
    echo "订阅：已配置"
  fi
  echo
  ss -lntup 2>/dev/null | grep -E ":${PROXY_PORT}|:${PANEL_PORT}" || true
}

edit_basic() {
  load_conf
  echo "直接回车表示保留当前值。"
  prompt_key LAN_IF "LAN 网卡" "$LAN_IF"
  prompt_key LAN_NET "LAN 网段" "$LAN_NET"
  prompt_key LAN_IP "旁路由 LAN IP" "$LAN_IP"
  prompt_key PROXY_PORT "代理端口" "$PROXY_PORT"
  prompt_key PANEL_PORT "面板端口" "$PANEL_PORT"
  prompt_key PANEL_SECRET "面板密钥" "$PANEL_SECRET"
  prompt_key DNS1 "DNS 1" "$DNS1"
  prompt_key DNS2 "DNS 2" "$DNS2"
  prompt_key SUBSCRIBE_URL "订阅/节点地址" "$SUBSCRIBE_URL"
  prompt_key SUBSCRIBE_URLS "更多订阅/节点地址" "$SUBSCRIBE_URLS"
  prompt_key SUBSCRIBE_USER_AGENT "订阅 User-Agent" "$SUBSCRIBE_USER_AGENT"
  echo
  echo "正在应用配置..."
  load_conf
  if [ -n "${SUBSCRIBE_URL:-}" ] || [ -n "${SUBSCRIBE_URLS:-}" ]; then
    update_subscription
  else
    apply_config
  fi
}

open_info() {
  load_conf
  zt_ip="$(detect_zt_ip || true)"
  cat <<EOF
请在浏览器打开：
  LAN 面板：http://${LAN_IP}:${PANEL_PORT}/ui/
$(if [ -n "$zt_ip" ]; then printf "  ZeroTier 面板：http://%s:%s/ui/\n" "$zt_ip" "$PANEL_PORT"; fi)

MetaCubeXD 要求填写后端时：
  LAN 后端：http://${LAN_IP}:${PANEL_PORT}
$(if [ -n "$zt_ip" ]; then printf "  ZeroTier 后端：http://%s:%s\n" "$zt_ip" "$PANEL_PORT"; fi)
  密钥：$(secret_status)

显式代理：
  LAN：http://${LAN_IP}:${PROXY_PORT}
$(if [ -n "$zt_ip" ]; then printf "  ZeroTier：http://%s:%s\n" "$zt_ip" "$PROXY_PORT"; fi)
EOF
}

show_panel_secret() {
  load_conf
  if [ -z "${PANEL_SECRET:-}" ]; then
    echo "面板密钥未设置。"
    return
  fi
  echo "面板密钥属于敏感信息。"
  printf "请输入 SHOW 后显示："
  read answer || answer=""
  if [ "$answer" = "SHOW" ]; then
    echo "面板密钥：${PANEL_SECRET}"
  else
    echo "已取消。"
  fi
}

main_menu() {
  need_root
  while true; do
    clear 2>/dev/null || true
    load_conf
    cat <<EOF
BypassProxy 旁路由代理助手 (bp)
==============================
1) 查看状态
2) 重启 sing-box
3) 查看日志
4) 显示面板/代理地址
5) 显示面板密钥
6) 修改基础设置（提示输入）
7) 更新订阅
8) 更新国内分流规则
9) 更新 Web 面板
10) 更新本项目脚本
11) 检查配置
12) 网络诊断
13) 应用旁路由转发/NAT
14) 干净卸载
15) 退出
EOF
    printf "请选择："
    read choice || exit 0
    case "$choice" in
      1) show_status; pause ;;
      2) apply_config; echo "已重启。"; pause ;;
      3) journalctl -u sing-box -f ;;
      4) open_info; pause ;;
      5) show_panel_secret; pause ;;
      6) edit_basic; pause ;;
      7) update_subscription; pause ;;
      8) update_rulesets; apply_config; pause ;;
      9) update_webui; pause ;;
      10) update_core; pause ;;
      11) check_config; pause ;;
      12) diagnose_network; pause ;;
      13) /usr/local/sbin/bypassproxy-forward.sh; echo "已应用。"; pause ;;
      14) uninstall_router; exit 0 ;;
      15|q|Q) exit 0 ;;
      *) echo "无效选择。"; pause ;;
    esac
  done
}

main_menu
