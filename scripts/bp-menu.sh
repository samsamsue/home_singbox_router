#!/bin/sh
set -eu

APP_DIR="${APP_DIR:-/opt/bypassproxy}"
CONF="${ROUTER_CONF:-/etc/bypassproxy/router.conf}"
CONFIG_JSON="/etc/sing-box/config.json"
SUBSCRIPTION_DIR="/etc/bypassproxy/subscriptions.d"

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
  ADMIN_PORT="${ADMIN_PORT:-8088}"
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

prompt_value() {
  label="$1"
  default="${2:-}"
  if [ -n "$default" ]; then
    printf "%s [%s]: " "$label" "$default" >&2
  else
    printf "%s: " "$label" >&2
  fi
  read value || value=""
  if [ -n "$value" ]; then
    printf "%s" "$value"
  else
    printf "%s" "$default"
  fi
}

secret_status() {
  if [ -n "${PANEL_SECRET:-}" ]; then
    printf "已设置"
  else
    printf "未设置"
  fi
}

quote_value() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

subscription_file() {
  id="$1"
  printf "%s/%03d.conf" "$SUBSCRIPTION_DIR" "$id"
}

next_subscription_id() {
  mkdir -p "$SUBSCRIPTION_DIR"
  max=0
  for item in "$SUBSCRIPTION_DIR"/*.conf; do
    [ -f "$item" ] || continue
    base="$(basename "$item" .conf)"
    case "$base" in
      [0-9][0-9][0-9])
        num="$(printf "%s" "$base" | sed 's/^0*//')"
        num="${num:-0}"
        [ "$num" -gt "$max" ] && max="$num"
        ;;
    esac
  done
  printf "%03d" $((max + 1))
}

write_subscription_item() {
  file="$1"
  name="$2"
  url="$3"
  enabled="${4:-1}"
  mkdir -p "$SUBSCRIPTION_DIR"
  cat > "$file" <<EOF
NAME='$(quote_value "$name")'
URL='$(quote_value "$url")'
ENABLED='$(quote_value "$enabled")'
EOF
  chmod 0600 "$file" 2>/dev/null || true
}

load_subscription_item() {
  file="$1"
  NAME=""
  URL=""
  ENABLED=1
  if [ -f "$file" ]; then
    # shellcheck disable=SC1090
    . "$file"
  fi
  NAME="${NAME:-$(basename "$file" .conf)}"
  URL="${URL:-}"
  ENABLED="${ENABLED:-1}"
}

list_subscriptions() {
  mkdir -p "$SUBSCRIPTION_DIR"
  found=0
  echo "订阅/节点列表："
  for item in "$SUBSCRIPTION_DIR"/*.conf; do
    [ -f "$item" ] || continue
    found=1
    load_subscription_item "$item"
    id="$(basename "$item" .conf)"
    if [ "$ENABLED" = "0" ]; then
      state="停用"
    else
      state="启用"
    fi
    printf "%s) [%s] %s\n" "$id" "$state" "$NAME"
    printf "    %s\n" "$URL"
  done
  if [ "$found" = "0" ]; then
    echo "  暂无。"
  fi
}

add_subscription_item() {
  mkdir -p "$SUBSCRIPTION_DIR"
  name="$(prompt_value "名称" "")"
  url="$(prompt_value "订阅/节点地址" "")"
  if [ -z "$url" ]; then
    echo "地址为空，已取消。"
    return
  fi
  if [ -z "$name" ]; then
    name="$url"
  fi
  id="$(next_subscription_id)"
  write_subscription_item "$(subscription_file "$id")" "$name" "$url" 1
  echo "已添加：$id"
}

select_subscription_file() {
  id="$(prompt_value "编号" "")"
  [ -n "$id" ] || return 1
  case "$id" in
    [0-9]) id="00$id" ;;
    [0-9][0-9]) id="0$id" ;;
  esac
  file="$(subscription_file "$id")"
  if [ ! -f "$file" ]; then
    echo "没有这个编号：$id" >&2
    return 1
  fi
  printf "%s" "$file"
}

delete_subscription_item() {
  list_subscriptions
  file="$(select_subscription_file)" || return
  load_subscription_item "$file"
  printf "确认删除 %s？输入 DELETE: " "$NAME"
  read answer || answer=""
  if [ "$answer" = "DELETE" ]; then
    rm -f "$file"
    echo "已删除。"
  else
    echo "已取消。"
  fi
}

toggle_subscription_item() {
  list_subscriptions
  file="$(select_subscription_file)" || return
  load_subscription_item "$file"
  if [ "$ENABLED" = "0" ]; then
    ENABLED=1
    echo "已启用：$NAME"
  else
    ENABLED=0
    echo "已停用：$NAME"
  fi
  write_subscription_item "$file" "$NAME" "$URL" "$ENABLED"
}

edit_subscription_item() {
  list_subscriptions
  file="$(select_subscription_file)" || return
  load_subscription_item "$file"
  new_name="$(prompt_value "名称" "$NAME")"
  new_url="$(prompt_value "订阅/节点地址" "$URL")"
  write_subscription_item "$file" "$new_name" "$new_url" "$ENABLED"
  echo "已修改。"
}

import_legacy_subscriptions() {
  load_conf
  mkdir -p "$SUBSCRIPTION_DIR"
  imported=0
  for source in $SUBSCRIBE_URL $SUBSCRIBE_URLS; do
    [ -n "$source" ] || continue
    id="$(next_subscription_id)"
    write_subscription_item "$(subscription_file "$id")" "$source" "$source" 1
    imported=$((imported + 1))
  done
  if [ "$imported" -gt 0 ]; then
    save_key SUBSCRIBE_URL ""
    save_key SUBSCRIBE_URLS ""
    echo "已导入 $imported 个旧地址，并清空基础设置里的旧地址。"
  else
    echo "没有可导入的旧地址。"
  fi
}

subscription_manager() {
  need_root
  while true; do
    clear 2>/dev/null || true
    cat <<EOF
订阅/节点管理
============
1) 查看列表
2) 添加订阅/节点
3) 删除订阅/节点
4) 启用/停用
5) 修改名称/地址
6) 导入基础设置里的旧地址
7) 更新并应用
8) 返回
EOF
    printf "请选择："
    read choice || return
    case "$choice" in
      1) list_subscriptions; pause ;;
      2) add_subscription_item; pause ;;
      3) delete_subscription_item; pause ;;
      4) toggle_subscription_item; pause ;;
      5) edit_subscription_item; pause ;;
      6) import_legacy_subscriptions; pause ;;
      7) update_subscription_choose_network; pause ;;
      8|q|Q) return ;;
      *) echo "无效选择。"; pause ;;
    esac
  done
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

pause_proxy() {
  echo "正在暂停 sing-box 代理服务..."
  systemctl disable --now sing-box
  echo "已暂停代理服务。Web 管理页仍会保留。"
}

resume_proxy() {
  echo "正在恢复 sing-box 代理服务..."
  apply_config
  systemctl enable --now sing-box
  if [ -x /usr/local/sbin/bypassproxy-forward.sh ]; then
    ROUTER_CONF="$CONF" /usr/local/sbin/bypassproxy-forward.sh
  fi
  echo "已恢复代理服务。"
}

update_subscription() {
  if [ ! -x /usr/local/sbin/bypassproxy-update-subscription.sh ]; then
    echo "缺少订阅更新脚本：/usr/local/sbin/bypassproxy-update-subscription.sh" >&2
    return 1
  fi
  ROUTER_CONF="$CONF" /usr/local/sbin/bypassproxy-update-subscription.sh
  apply_config
}

update_subscription_choose_network() {
  printf "本次下载订阅是否直连，不使用代理？[y/N]: "
  read answer || answer=""
  case "$answer" in
    y|Y|yes|YES)
      BYPASSPROXY_DIRECT_DOWNLOAD=1 ROUTER_CONF="$CONF" /usr/local/sbin/bypassproxy-update-subscription.sh
      ;;
    *)
      ROUTER_CONF="$CONF" /usr/local/sbin/bypassproxy-update-subscription.sh
      ;;
  esac
  apply_config
}

update_webui() {
  if [ ! -x /usr/local/sbin/bypassproxy-update-webui.sh ]; then
    echo "缺少节点面板更新脚本：/usr/local/sbin/bypassproxy-update-webui.sh" >&2
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

admin_web_status() {
  load_conf
  state="$(systemctl is-active bypassproxy-admin 2>/dev/null || true)"
  enabled="$(systemctl is-enabled bypassproxy-admin 2>/dev/null || true)"
  zt_ip="$(detect_zt_ip || true)"
  echo "管理后台状态：${state:-unknown}"
  echo "开机自启：${enabled:-unknown}"
  echo "LAN 地址：http://${LAN_IP}:${ADMIN_PORT}/"
  if [ -n "$zt_ip" ]; then
    echo "ZeroTier 地址：http://${zt_ip}:${ADMIN_PORT}/"
  fi
  echo "登录密钥：$(secret_status)"
}

start_admin_web() {
  systemctl daemon-reload
  systemctl enable --now bypassproxy-admin
  admin_web_status
}

stop_admin_web() {
  systemctl disable --now bypassproxy-admin
  admin_web_status
}

restart_admin_web() {
  systemctl restart bypassproxy-admin
  admin_web_status
}

edit_admin_port() {
  load_conf
  prompt_key ADMIN_PORT "管理后台端口" "$ADMIN_PORT"
  echo "端口已保存。若管理后台正在运行，请选择“重启管理后台”。"
}

admin_web_menu() {
  need_root
  while true; do
    clear 2>/dev/null || true
    cat <<EOF
管理后台
==========
1) 查看状态/地址
2) 开启管理后台
3) 关闭管理后台
4) 重启管理后台
5) 修改端口
6) 返回
EOF
    printf "请选择："
    read choice || return
    case "$choice" in
      1) admin_web_status; pause ;;
      2) start_admin_web; pause ;;
      3) stop_admin_web; pause ;;
      4) restart_admin_web; pause ;;
      5) edit_admin_port; pause ;;
      6|q|Q) return ;;
      *) echo "无效选择。"; pause ;;
    esac
  done
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

repair_system() {
  if [ -x /usr/local/sbin/bypassproxy-repair.sh ]; then
    ROUTER_CONF="$CONF" /usr/local/sbin/bypassproxy-repair.sh
    return
  fi
  if [ -x "$APP_DIR/scripts/repair.sh" ]; then
    ROUTER_CONF="$CONF" "$APP_DIR/scripts/repair.sh"
    return
  fi
  echo "缺少一键修复脚本。" >&2
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
  echo "节点面板地址：http://${LAN_IP}:${PANEL_PORT}/ui/"
  echo "节点面板后端：http://${LAN_IP}:${PANEL_PORT}"
  echo "管理后台：http://${LAN_IP}:${ADMIN_PORT}/ ($(systemctl is-active bypassproxy-admin 2>/dev/null || true))"
  echo "登录密钥：$(secret_status)"
  echo "显式代理：http://${LAN_IP}:${PROXY_PORT}"
  zt_ip="$(detect_zt_ip || true)"
  if [ -n "$zt_ip" ]; then
    echo
    echo "ZeroTier 节点面板：http://${zt_ip}:${PANEL_PORT}/ui/"
    echo "ZeroTier 管理后台：http://${zt_ip}:${ADMIN_PORT}/"
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
  prompt_key PANEL_SECRET "登录密钥" "$PANEL_SECRET"
  prompt_key ADMIN_PORT "管理后台端口" "$ADMIN_PORT"
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
  LAN 节点面板：http://${LAN_IP}:${PANEL_PORT}/ui/
  管理后台：http://${LAN_IP}:${ADMIN_PORT}/
$(if [ -n "$zt_ip" ]; then printf "  ZeroTier 节点面板：http://%s:%s/ui/\n" "$zt_ip" "$PANEL_PORT"; fi)
$(if [ -n "$zt_ip" ]; then printf "  ZeroTier 管理后台：http://%s:%s/\n" "$zt_ip" "$ADMIN_PORT"; fi)

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
    echo "登录密钥未设置。"
    return
  fi
  echo "登录密钥属于敏感信息。"
  printf "请输入 SHOW 后显示："
  read answer || answer=""
  if [ "$answer" = "SHOW" ]; then
    echo "登录密钥：${PANEL_SECRET}"
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
BypassProxy 管理菜单 (bp)
========================
常用控制
  1) 查看状态
  2) 暂停代理
  3) 恢复代理
  4) 重启代理
  5) 网络诊断

订阅和节点
  6) 订阅/节点管理
  7) 更新订阅并应用
  8) 更新国内分流规则
  9) 更新节点面板(MetaCubeXD)

入口和设置
 10) 显示入口地址
 11) 管理后台
 12) 修改基础设置
 13) 显示登录密钥

维护修复
 14) 检查配置
 15) 应用旁路由转发/NAT
 16) 一键修复
 17) 查看日志
 18) 更新本项目脚本

危险操作
 19) 干净卸载
 20) 退出
EOF
    printf "请选择："
    read choice || exit 0
    case "$choice" in
      1) show_status; pause ;;
      2) pause_proxy; pause ;;
      3) resume_proxy; pause ;;
      4) apply_config; echo "已重启。"; pause ;;
      5) diagnose_network; pause ;;
      6) subscription_manager ;;
      7) update_subscription; pause ;;
      8) update_rulesets; apply_config; pause ;;
      9) update_webui; pause ;;
      10) open_info; pause ;;
      11) admin_web_menu ;;
      12) edit_basic; pause ;;
      13) show_panel_secret; pause ;;
      14) check_config; pause ;;
      15) /usr/local/sbin/bypassproxy-forward.sh; echo "已应用。"; pause ;;
      16) repair_system; pause ;;
      17) journalctl -u sing-box -f ;;
      18) update_core; pause ;;
      19) uninstall_router; exit 0 ;;
      20|q|Q) exit 0 ;;
      *) echo "无效选择。"; pause ;;
    esac
  done
}

main_menu
