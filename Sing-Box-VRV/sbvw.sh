#!/bin/bash
#===============================================================================
# wget -N --no-check-certificate "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbvw.sh" && chmod +x sbvw.sh && ./sbvw.sh
# Thanks: sing-box project(https://github.com/SagerNet/sing-box), fscarmen/warp-sh project(https://github.com/fscarmen/warp-sh)
#===============================================================================

SCRIPT_VERSION="2.2.6"
INSTALL_PATH="/root/sbvw.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_PATH="/etc/sing-box/config.json"
CONFIG_BACKUP_PATH="/etc/sing-box/config.json.backup"
INFO_PATH_VRV="/etc/sing-box/vrv_info.env"
INFO_PATH_VRVW="/etc/sing-box/vrvw_info.env"

SINGBOX_BINARY=""
WARP_SCRIPT_URL="https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"
LAST_OUTBOUND_TYPE=""

trap 'echo -en "${NC}"' EXIT

# ==================== 增强的错误处理 ====================
error_exit() { echo -e "${RED}❌ 错误：$1${NC}"; exit 1; }
success_msg() { echo -e "${GREEN}✓ $1${NC}"; }
warning_msg() { echo -e "${YELLOW}⚠ $1${NC}"; }

# ==================== 日志记录 ====================
log_action() {
  local action="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $action" >> /var/log/sbvw.log
}

# ==================== 权限检查 ====================
check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    error_exit "此脚本必须以 root 权限运行。"
  fi
}

# ==================== 依赖检查 ====================
check_dependencies() {
  for cmd in curl jq openssl wget ping ss; do
    if ! command -v "$cmd" &> /dev/null; then
      warning_msg "依赖 '$cmd' 未安装，正在尝试自动安装..."
      if command -v apt-get &> /dev/null; then
        apt-get update >/dev/null 2>&1
        apt-get install -y "$cmd" dnsutils iproute2 >/dev/null 2>&1
      elif command -v yum &> /dev/null; then
        yum install -y "$cmd" bind-utils iproute >/dev/null 2>&1
      elif command -v dnf &> /dev/null; then
        dnf install -y "$cmd" bind-utils iproute >/dev/null 2>&1
      else
        error_exit "无法确定包管理器。请手动安装 '$cmd'。"
      fi
      if ! command -v "$cmd" &> /dev/null; then
        error_exit "'$cmd' 自动安装失败。"
      fi
      success_msg "'$cmd' 安装成功"
    fi
  done
}

# ==================== 修复：WireProxy 出站状态检查与恢复 ====================
check_wireproxy_health() {
  if ! systemctl is-active --quiet wireproxy; then
    warning_msg "WireProxy 服务未运行"
    return 1
  fi
  if ! ss -tlpn 2>/dev/null | grep -q ":40043 "; then
    warning_msg "WireProxy SOCKS5 端口 40043 未被监听"
    return 1
  fi
  return 0
}

restore_direct_outbound() {
  [[ -f "$CONFIG_PATH" ]] || return 0

  local current_outbound_type
  current_outbound_type=$(jq -r '.outbounds[0].type // empty' "$CONFIG_PATH" 2>/dev/null)

  if [[ "$current_outbound_type" == "socks" ]]; then
    echo "检测到当前使用 WARP 出站，正在检查 WireProxy 状态..."
    if ! check_wireproxy_health; then
      warning_msg "WireProxy 已停止或不可用，自动恢复为直连出站"
      cp "$CONFIG_PATH" "${CONFIG_PATH}.warp-backup" 2>/dev/null || true

      jq '.outbounds[0] = { "type": "direct", "tag": "direct", "tcp_fast_open": true }' \
        "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH" \
        || error_exit "配置更新失败"

      success_msg "配置已恢复为直连出站"
      systemctl restart sing-box
      log_action "自动恢复直连出站（WireProxy 不可用）"
    fi
  fi

  return 0
}

# ==================== TFO 状态检查 ====================
check_tfo_status() {
  local tfo_value
  tfo_value=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "0")
  if [[ "$tfo_value" == "3" ]]; then
    success_msg "TCP Fast Open (TFO) 状态: 已开启"
  else
    warning_msg "TCP Fast Open (TFO) 状态: 未开启（可能影响性能）"
  fi
}

# ==================== 安装 Sing-Box 核心 ====================
install_singbox_core() {
  echo ">>> 正在安装/更新 sing-box 最新稳定版..."
  if ! bash <(curl -fsSL https://sing-box.app/deb-install.sh); then
    error_exit "sing-box 核心安装失败。"
  fi

  SINGBOX_BINARY=$(command -v sing-box)
  [[ -n "$SINGBOX_BINARY" ]] || error_exit "未能找到 sing-box 可执行文件。"

  success_msg "sing-box 核心安装成功！版本：$($SINGBOX_BINARY version | head -n 1)"
  log_action "Sing-Box 核心安装/更新完成"
  return 0
}

# ==================== 安装 WARP ====================
install_warp() {
  echo ">>> 正在下载并启动 WARP 管理脚本..."
  local warp_installer="/root/fscarmen-warp.sh"
  if ! wget -N "$WARP_SCRIPT_URL" -O "$warp_installer" 2>/dev/null; then
    error_exit "下载 WARP 管理脚本失败。"
  fi
  chmod +x "$warp_installer"

  clear
  echo "====================================================="
  echo " 进入 WARP 管理菜单（建议选择 WireProxy SOCKS5 模式）"
  echo " 要求：最终 WireProxy 监听 127.0.0.1:40043"
  echo "====================================================="
  bash "$warp_installer"

  if ! check_wireproxy_health; then
    error_exit "WireProxy 未正常运行或未监听 40043。"
  fi

  success_msg "WireProxy 已成功安装并运行！"
  log_action "WireProxy 安装完成"
  return 0
}

# ==================== Reality 域名检查 ====================
check_reality_domain() {
  local domain="$1"
  local success_count=0

  echo "正在检测 ${domain} 的 Reality 可用性（连续5次）..."
  for i in {1..5}; do
    if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 10 "https://${domain}" 2>&1 | grep -q "SSL connection using TLSv1.3"; then
      success_msg "SUCCESS: $domain 第 $i 次检测通过。"
      ((success_count++))
    else
      echo -e "${RED}✗ FAILURE: $domain 第 $i 次检测失败。${NC}"
    fi
    sleep 1
  done

  [[ $success_count -ge 4 ]]
}

# ==================== 显示摘要 ====================
show_summary() {
  local info_file="$1"
  [[ -f "$info_file" ]] || error_exit "信息文件不存在：$info_file"

  # shellcheck disable=SC1090
  source "$info_file"

  local outbound_info="direct"
  if [[ "${OUTBOUND_TYPE:-}" == "warp" ]]; then
    outbound_info="warp (wireproxy socks5 127.0.0.1:40043)"
  fi

  local vless_uri="vless://${UUID}@${SERVER_IP}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&reality=1&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&sni=${HANDSHAKE_SERVER}#Reality"

  clear
  echo "====================================================="
  echo " Sing-Box-(VLESS+Reality+Vision) 配置信息"
  echo "====================================================="
  echo "服务端配置文件：${CONFIG_PATH}"
  echo "信息文件：${info_file}"
  echo "-------------------------------------------------"
  echo -e "${GREEN}VLESS 导入链接${NC}"
  echo "${vless_uri}"
  echo "-------------------------------------------------"
  echo "server      : ${SERVER_IP}"
  echo "port        : ${LISTEN_PORT}"
  echo "uuid        : ${UUID}"
  echo "flow        : xtls-rprx-vision"
  echo "servername  : ${HANDSHAKE_SERVER}"
  echo "public-key  : ${PUBLIC_KEY}"
  echo "short-id    : ${SHORT_ID}"
  echo "-------------------------------------------------"
  echo -e "${GREEN}出站#Outbounds${NC}: ${outbound_info}"
  echo "-------------------------------------------------"
  echo "建议测试：ping ${HANDSHAKE_SERVER}"
  echo "-------------------------------------------------"
}

# ==================== 生成配置文件 ====================
generate_config() {
  local outbound_type="$1"

  echo ">>> 正在配置 VLESS + Reality + Vision..."

  local listen_addr="::"
  local listen_port=443
  local co_exist_mode=false

  if ss -tlpn 2>/dev/null | grep -q ":${listen_port} "; then
    co_exist_mode=true
    listen_addr="127.0.0.1"
    warning_msg "检测到 443 端口已被占用，将切换到'网站共存'模式。"
    read -p "请输入 sing-box 用于内部监听的端口 [默认 10443]: " custom_port
    listen_port=${custom_port:-10443}
  fi

  local handshake_server
  while true; do
    echo -en "${GREEN}请输入 Reality 域名（示例：www.bing.com）: ${NC}"
    read -r handshake_server
    handshake_server=${handshake_server:-www.bing.com}

    if check_reality_domain "$handshake_server"; then
      success_msg "最终检测：$handshake_server 适合 Reality SNI，继续安装。"
      break
    else
      echo -e "${RED}检测未通过（连续5次至少通过4次才算合格）。请更换其它 Reality 域名。${NC}"
      read -p "是否 [R]重新输入 或 [Q]退出脚本? (R/Q): " choice
      case "${choice,,}" in
        q|quit) error_exit "安装已中止。" ;;
        *) continue ;;
      esac
    fi
  done

  [[ -n "$SINGBOX_BINARY" ]] || SINGBOX_BINARY=$(command -v sing-box)
  [[ -n "$SINGBOX_BINARY" ]] || error_exit "未检测到 sing-box。"

  echo "正在生成密钥与 ID..."
  local key_pair private_key public_key uuid short_id
  key_pair=$($SINGBOX_BINARY generate reality-keypair) || error_exit "生成 reality-keypair 失败。"
  private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
  public_key=$(echo "$key_pair"  | awk '/PublicKey/  {print $2}' | tr -d '"')
  uuid=$($SINGBOX_BINARY generate uuid) || error_exit "生成 UUID 失败。"
  short_id=$(openssl rand -hex 8) || error_exit "生成 short_id 失败。"

  mkdir -p /etc/sing-box

  local outbound_config
  if [[ "$outbound_type" == "warp" ]]; then
    outbound_config='{ "type": "socks", "tag": "warp-out", "server": "127.0.0.1", "server_port": 40043, "version": "5", "tcp_fast_open": true, "username": "", "password": "" }'
    LAST_OUTBOUND_TYPE="warp"
  else
    outbound_config='{ "type": "direct", "tag": "direct", "tcp_fast_open": true }'
    LAST_OUTBOUND_TYPE="direct"
  fi

  # 初装仍保持脚本默认：禁用日志（与 2.2.5 行为一致）
  jq -n \
    --arg listen_addr "$listen_addr" \
    --argjson listen_port "$listen_port" \
    --arg uuid "$uuid" \
    --arg server_name "$handshake_server" \
    --arg private_key "$private_key" \
    --arg short_id "$short_id" \
    --argjson outbound_config "$outbound_config" \
    '{
      "log": { "disabled": true },
      "inbounds": [
        {
          "type": "vless",
          "tag": "vless-in",
          "listen": $listen_addr,
          "listen_port": $listen_port,
          "sniff": true,
          "sniff_override_destination": true,
          "tcp_fast_open": true,
          "users": [ { "uuid": $uuid, "flow": "xtls-rprx-vision" } ],
          "tls": {
            "enabled": true,
            "server_name": $server_name,
            "reality": {
              "enabled": true,
              "handshake": { "server": $server_name, "server_port": 443 },
              "private_key": $private_key,
              "short_id": [ "", $short_id ]
            }
          }
        }
      ],
      "outbounds": [ $outbound_config ]
    }' > "$CONFIG_PATH" || error_exit "写入配置失败。"

  local info_file_path
  if [[ "$outbound_type" == "warp" ]]; then
    info_file_path="$INFO_PATH_VRVW"
  else
    info_file_path="$INFO_PATH_VRV"
  fi

  local server_ip
  server_ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "unknown")

  cat > "$info_file_path" <<EOF
# Generated by sbvw.sh
OUTBOUND_TYPE=${outbound_type}
HANDSHAKE_SERVER=${handshake_server}
LISTEN_ADDR=${listen_addr}
LISTEN_PORT=${listen_port}
SERVER_IP=${server_ip}
UUID=${uuid}
PUBLIC_KEY=${public_key}
SHORT_ID=${short_id}
EOF

  show_summary "$info_file_path"
}

# ==================== 切换 Reality 域名 ====================
change_reality_domain() {
  [[ -f "$CONFIG_PATH" ]] || error_exit "配置文件不存在。"

  read -p "请输入新的 Reality 域名: " new_domain
  [[ -n "$new_domain" ]] || error_exit "域名不能为空。"

  if ! check_reality_domain "$new_domain"; then
    warning_msg "域名检测未通过，但仍然保存配置"
  fi

  jq --arg new_domain "$new_domain" \
    '.inbounds[0].tls.reality.handshake.server = $new_domain
     | .inbounds[0].tls.server_name = $new_domain' \
    "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH" \
    || error_exit "配置更新失败！"

  local info_file=""
  if [[ -f "$INFO_PATH_VRV" ]]; then info_file="$INFO_PATH_VRV"; fi
  if [[ -f "$INFO_PATH_VRVW" ]]; then info_file="$INFO_PATH_VRVW"; fi
  if [[ -n "$info_file" ]]; then
    sed -i "s/^HANDSHAKE_SERVER=.*/HANDSHAKE_SERVER=${new_domain}/" "$info_file" 2>/dev/null || true
  fi

  systemctl restart sing-box
  if systemctl is-active --quiet sing-box; then
    success_msg "Reality 域名已更改为: $new_domain"
    log_action "Reality 域名已更改"
  else
    error_exit "sing-box 重启失败！"
  fi
}

# ==================== 新功能：重新生成新配置（Reality 域名不变，且不动原 log 配置） ====================
regenerate_config_keep_domain() {
  [[ -f "$CONFIG_PATH" ]] || error_exit "配置文件不存在：$CONFIG_PATH，请先安装。"

  [[ -n "$SINGBOX_BINARY" ]] || SINGBOX_BINARY=$(command -v sing-box)
  [[ -n "$SINGBOX_BINARY" ]] || error_exit "未检测到 sing-box，可执行文件不存在。"

  local handshake_server listen_addr listen_port
  handshake_server=$(jq -r '.inbounds[0].tls.reality.handshake.server // empty' "$CONFIG_PATH" 2>/dev/null)
  [[ -n "$handshake_server" && "$handshake_server" != "null" ]] || error_exit "无法从现有配置提取 Reality 域名。"

  listen_addr=$(jq -r '.inbounds[0].listen // "::"' "$CONFIG_PATH" 2>/dev/null)
  listen_port=$(jq -r '.inbounds[0].listen_port // 443' "$CONFIG_PATH" 2>/dev/null)

  # 保留原 log 配置（关键点：不要动）
  local old_log_json
  old_log_json=$(jq -c '.log // {}' "$CONFIG_PATH" 2>/dev/null)
  [[ -n "$old_log_json" && "$old_log_json" != "null" ]] || old_log_json='{}'

  # 读取现有出站（保留 direct / warp socks）
  local out0_type outbound_type outbound_obj info_file_path
  out0_type=$(jq -r '.outbounds[0].type // "direct"' "$CONFIG_PATH" 2>/dev/null)

  if [[ "$out0_type" == "socks" ]]; then
    outbound_type="warp"
    outbound_obj=$(jq -c '.outbounds[0]' "$CONFIG_PATH" 2>/dev/null)
    info_file_path="$INFO_PATH_VRVW"
  else
    outbound_type="direct"
    outbound_obj=$(jq -c '.outbounds[0]' "$CONFIG_PATH" 2>/dev/null)
    info_file_path="$INFO_PATH_VRV"
  fi
  [[ -n "$outbound_obj" && "$outbound_obj" != "null" ]] || error_exit "无法读取现有 outbounds[0]。"

  echo "====================================================="
  echo " 重新生成新配置（Reality 域名不变）"
  echo "-----------------------------------------------------"
  echo " Reality 域名 (保持): $handshake_server"
  echo " listen           : ${listen_addr}:${listen_port}"
  echo " outbound         : $outbound_type"
  echo "====================================================="
  read -p "确认继续？(y/N): " confirm
  [[ "${confirm,,}" == "y" ]] || { echo "已取消。"; return 0; }

  if ! check_reality_domain "$handshake_server"; then
    warning_msg "Reality 域名检测未通过（但仍会继续重建配置，域名保持不变）。"
  fi

  echo ">>> 正在生成新的 Reality keypair / UUID / short_id ..."
  local key_pair private_key public_key uuid short_id
  key_pair=$($SINGBOX_BINARY generate reality-keypair) || error_exit "生成 reality-keypair 失败。"
  private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
  public_key=$(echo "$key_pair"  | awk '/PublicKey/  {print $2}' | tr -d '"')
  uuid=$($SINGBOX_BINARY generate uuid) || error_exit "生成 UUID 失败。"
  short_id=$(openssl rand -hex 8) || error_exit "生成 short_id 失败。"

  # 写回 config.json：保留 old_log_json + outbound_obj + (domain/port等不变)
  jq -n \
    --argjson old_log "$old_log_json" \
    --arg listen_addr "$listen_addr" \
    --argjson listen_port "$listen_port" \
    --arg uuid "$uuid" \
    --arg server_name "$handshake_server" \
    --arg private_key "$private_key" \
    --arg short_id "$short_id" \
    --argjson outbound_config "$outbound_obj" \
    '{
      "log": $old_log,
      "inbounds": [
        {
          "type": "vless",
          "tag": "vless-in",
          "listen": $listen_addr,
          "listen_port": $listen_port,
          "sniff": true,
          "sniff_override_destination": true,
          "tcp_fast_open": true,
          "users": [ { "uuid": $uuid, "flow": "xtls-rprx-vision" } ],
          "tls": {
            "enabled": true,
            "server_name": $server_name,
            "reality": {
              "enabled": true,
              "handshake": { "server": $server_name, "server_port": 443 },
              "private_key": $private_key,
              "short_id": [ "", $short_id ]
            }
          }
        }
      ],
      "outbounds": [ $outbound_config ]
    }' > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH" || error_exit "写入新配置失败。"

  local server_ip
  server_ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "unknown")

  cat > "$info_file_path" <<EOF
# Generated by sbvw.sh (regenerate)
OUTBOUND_TYPE=${outbound_type}
HANDSHAKE_SERVER=${handshake_server}
LISTEN_ADDR=${listen_addr}
LISTEN_PORT=${listen_port}
SERVER_IP=${server_ip}
UUID=${uuid}
PUBLIC_KEY=${public_key}
SHORT_ID=${short_id}
EOF

  systemctl restart sing-box
  sleep 1
  systemctl is-active --quiet sing-box || error_exit "sing-box 重启失败，请检查：journalctl -u sing-box -n 100 --no-pager"

  success_msg "✅ 已重新生成新配置（Reality 域名保持不变 / 保留原 log）"
  log_action "重新生成新配置（Reality 域名不变）"

  show_summary "$info_file_path"
  read -n 1 -s -r -p "按任意键返回主菜单..."
}

# ==================== 日志控制 ====================
check_and_toggle_log_status() {
  [[ -f "$CONFIG_PATH" ]] || error_exit "配置文件不存在。"

  local log_status new_status status_text
  log_status=$(jq -r '.log.disabled // empty' "$CONFIG_PATH" 2>/dev/null)

  new_status="true"
  status_text="关闭"
  if [[ "$log_status" == "true" ]]; then
    new_status="false"
    status_text="开启"
  fi

  jq ".log.disabled = $new_status" "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" \
    && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH" \
    || error_exit "更新日志配置失败"

  systemctl restart sing-box
  success_msg "日志已${status_text}"
  log_action "日志状态已切换"
}

view_log() {
  if ! systemctl is-active --quiet sing-box; then
    error_exit "sing-box 未运行。"
  fi
  echo "--- 实时 Sing-Box 日志 (按 Ctrl+C 退出) ---"
  journalctl -u sing-box -f --no-pager
}

auto_disable_log_on_start() {
  # 保持原脚本行为：启动时如果日志开启，则自动关掉（不改你新增功能的“重生成不动 log”原则）
  if [[ -f "$CONFIG_PATH" ]]; then
    local log_status
    log_status=$(jq -r '.log.disabled // empty' "$CONFIG_PATH" 2>/dev/null)
    if [[ "$log_status" != "true" && -n "$log_status" ]]; then
      jq '.log.disabled = true' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
      systemctl restart sing-box >/dev/null 2>&1 || true
    fi
  fi
}

# ==================== 标准安装 ====================
install_standard() {
  clear
  echo "========================================="
  echo " 安装 Sing-Box (标准直连出站)"
  echo "========================================="
  check_tfo_status

  install_singbox_core
  generate_config "direct"

  systemctl enable sing-box
  systemctl restart sing-box
  sleep 2
  systemctl is-active --quiet sing-box || error_exit "Sing-Box 启动失败。"

  success_msg "✅ Sing-Box 标准版安装完成！"
  show_summary "$INFO_PATH_VRV"
  log_action "标准版安装完成"
}

# ==================== WARP 版安装 ====================
install_with_warp() {
  clear
  echo "========================================="
  echo " 安装 Sing-Box + WARP (WARP出站)"
  echo "========================================="
  check_tfo_status

  install_singbox_core
  install_warp
  generate_config "warp"

  systemctl enable sing-box
  systemctl restart sing-box
  sleep 2
  systemctl is-active --quiet sing-box || error_exit "Sing-Box 启动失败。"

  success_msg "✅ Sing-Box WARP 版安装完成！"
  show_summary "$INFO_PATH_VRVW"
  log_action "WARP 版安装完成"
}

# ==================== 升级到 WARP 版 ====================
upgrade_to_warp() {
  clear
  echo "========================================="
  echo " 升级至 WARP 版本"
  echo "========================================="

  [[ -f "$INFO_PATH_VRV" ]] || error_exit "未检测到标准版配置。"

  install_warp

  echo "正在升级配置文件..."
  local warp_outbound
  warp_outbound='{ "type": "socks", "tag": "warp-out", "server": "127.0.0.1", "server_port": 40043, "version": "5", "tcp_fast_open": true, "username": "", "password": "" }'

  jq --argjson new_outbound "$warp_outbound" '.outbounds = [$new_outbound]' \
    "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH" \
    || error_exit "配置文件升级失败！"

  # 保持原 2.2.5 行为：升级时禁用日志
  jq '.log = {"disabled": true}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

  systemctl restart sing-box
  sleep 2

  mv "$INFO_PATH_VRV" "$INFO_PATH_VRVW" 2>/dev/null || true
  if ! grep -q '^OUTBOUND_TYPE=' "$INFO_PATH_VRVW" 2>/dev/null; then
    echo "OUTBOUND_TYPE=warp" >> "$INFO_PATH_VRVW"
  else
    sed -i 's/^OUTBOUND_TYPE=.*/OUTBOUND_TYPE=warp/' "$INFO_PATH_VRVW"
  fi

  systemctl is-active --quiet sing-box || error_exit "sing-box 服务重启失败。"

  success_msg "✅ 升级成功，已切换到 WARP 出站"
  show_summary "$INFO_PATH_VRVW"
  log_action "已升级至 WARP 版本"
}

# ==================== 更新脚本 ====================
update_script() {
  local temp_script_path="/root/sbvw.sh.new"
  if ! curl -fsSL "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbvw.sh" -o "$temp_script_path"; then
    warning_msg "下载新版本脚本失败。"
    rm -f "$temp_script_path"
    return 1
  fi

  local new_version
  new_version=$(grep 'SCRIPT_VERSION="' "$temp_script_path" | awk -F '"' '{print $2}')
  [[ -n "$new_version" ]] || error_exit "未检测到新脚本版本号。"

  if [[ "$SCRIPT_VERSION" != "$new_version" ]]; then
    echo -e "${GREEN}发现新版本 v${new_version}，是否更新? (y/N): ${NC}"
    read -r confirm
    if [[ "${confirm,,}" == "y" ]]; then
      cat "$temp_script_path" > "$INSTALL_PATH"
      chmod +x "$INSTALL_PATH"
      rm -f "$temp_script_path"
      success_msg "脚本已成功更新至 v${new_version}！"
      echo "请重新运行 ./sbvw.sh 使用新版本。"
      exit 0
    else
      rm -f "$temp_script_path"
    fi
  else
    success_msg "脚本已是最新版本 (v${SCRIPT_VERSION})。"
    rm -f "$temp_script_path"
  fi
}

# ==================== 服务管理 ====================
manage_service() {
  while true; do
    clear
    local log_status service_status

    if [[ -f "$CONFIG_PATH" ]]; then
      log_status=$(jq -r '.log.disabled // empty' "$CONFIG_PATH" 2>/dev/null)
    fi

    if systemctl is-active --quiet sing-box; then
      service_status="${GREEN}运行中${NC}"
    else
      service_status="${RED}已停止${NC}"
    fi

    echo "--- Sing-Box 服务管理 ---"
    echo "状态: $service_status"
    echo "-------------------------"
    echo " 1. 重启服务"
    echo " 2. 停止服务"
    echo " 3. 启动服务"
    echo " 4. 查看状态"
    echo " 5. 查看实时日志"
    if [[ "$log_status" == "true" ]]; then
      echo " 6. 日志已关闭（点此开启）"
    else
      echo " 6. 日志已开启（点此关闭）"
    fi
    echo " 0. 返回主菜单"
    echo "-------------------------"

    read -p "请输入选项: " sub_choice
    case $sub_choice in
      1) systemctl restart sing-box; success_msg "sing-box 服务已重启。"; sleep 1 ;;
      2) systemctl stop sing-box; warning_msg "sing-box 服务已停止。"; sleep 1 ;;
      3) systemctl start sing-box; restore_direct_outbound; success_msg "sing-box 服务已启动。"; sleep 1 ;;
      4) systemctl status sing-box; read -n 1 -s -r -p "按任意键返回服务菜单..." ;;
      5) view_log ;;
      6) check_and_toggle_log_status; sleep 1 ;;
      0) return ;;
      *) echo -e "\n${RED}✗ 无效选项。${NC}"; sleep 1 ;;
    esac
  done
}

# ==================== 卸载 ====================
uninstall_vrvw() {
  echo -e "${RED}警告：此操作将卸载 sing-box 及本脚本。WARP 不会被卸载。要删除配置文件吗? [Y/n]: ${NC}"
  read -r confirm_delete

  local keep_config=false
  if [[ "${confirm_delete,,}" == "n" ]]; then
    keep_config=true
  fi

  systemctl stop sing-box &>/dev/null || true
  systemctl disable sing-box &>/dev/null || true

  local bin_path
  bin_path=$(command -v sing-box || true)

  if [[ "$keep_config" == false ]]; then
    echo "正在删除 sing-box 文件 (包括配置文件)..."
    rm -rf /etc/sing-box
  else
    echo "正在删除 sing-box 核心组件 (保留配置文件)..."
  fi

  rm -f /etc/systemd/system/sing-box.service
  [[ -n "$bin_path" ]] && rm -f "$bin_path"
  systemctl daemon-reload

  rm -f "$INSTALL_PATH"
  log_action "已卸载 Sing-Box"
  success_msg "Sing-Box-VRVW 已被移除。"
}

# ==================== 脚本安装 ====================
install_script_if_needed() {
  if [[ "$(realpath "$0")" != "$INSTALL_PATH" ]]; then
    echo ">>> 首次运行，正在安装管理脚本..."
    cp -f "$(realpath "$0")" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    success_msg "管理脚本已安装到 ${INSTALL_PATH}"
    echo "正在重新加载..."
    sleep 1
    exec bash "$INSTALL_PATH"
  fi
}

# ==================== 服务状态显示 ====================
get_service_status() {
  local service_name="$1"
  local display_name="$2"
  if ! systemctl is-active --quiet "$service_name"; then
    printf "%-12s: %b\n" "$display_name" "${RED}已停止${NC}"
  else
    printf "%-12s: %b\n" "$display_name" "${GREEN}运行中${NC}"
  fi
}

# ==================== 主菜单 ====================
main_menu() {
  install_script_if_needed
  auto_disable_log_on_start
  restore_direct_outbound

  while true; do
    clear

    local is_sbv_installed="false"
    local is_sbvw_installed="false"
    [[ -f "$INFO_PATH_VRV" ]] && is_sbv_installed="true"
    [[ -f "$INFO_PATH_VRVW" ]] && is_sbvw_installed="true"

    echo "======================================================"
    echo " Sing-Box VRV & WARP 统一管理平台 v${SCRIPT_VERSION} "
    if [[ "$is_sbv_installed" == "true" || "$is_sbvw_installed" == "true" ]]; then
      echo "--------------------------------------------------"
      get_service_status "sing-box" "Sing-Box"
      if command -v warp &>/dev/null; then
        get_service_status "wireproxy" "WireProxy"
      fi
    fi
    echo "======================================================"
    echo "--- 安装选项 ---"
    echo " 1. 安装 Sing-Box (标准直连出站)"
    echo " 2. 安装 Sing-Box + WARP (WARP出站)"
    if [[ "$is_sbv_installed" == "true" ]]; then
      echo -e " 3. ${GREEN}为现有 Sing-Box 添加 WARP (升级)${NC}"
    fi
    echo "--- 管理选项 ---"
    echo " 4. 查看配置信息"
    echo " 5. 更新 Sing-Box Core"
    echo " 6. 管理 Sing-Box 服务"
    echo " 7. 更换 Reality 域名"
    echo " 8. 管理 WARP (调用 warp 命令)"
    echo " 12. 重新生成新配置（Reality 域名不变）"
    echo "--- 维护选项 ---"
    echo " 9. 更新脚本"
    echo " 10. 检查并修复出站状态"
    echo " 11. 彻底卸载"
    echo " 0. 退出脚本"
    echo "======================================================"

    read -p "请输入你的选项: " choice
    case "${choice,,}" in
      1) install_standard; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
      2) install_with_warp; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
      3)
        if [[ "$is_sbv_installed" == "true" ]]; then
          upgrade_to_warp
        else
          echo -e "\n${RED}✗ 无效选项。${NC}"
        fi
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      4)
        if [[ "$is_sbv_installed" == "true" ]]; then
          show_summary "$INFO_PATH_VRV"
        elif [[ "$is_sbvw_installed" == "true" ]]; then
          show_summary "$INFO_PATH_VRVW"
        else
          error_exit "请先安装。"
        fi
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      5)
        SINGBOX_BINARY=$(command -v sing-box || true)
        if [[ -n "$SINGBOX_BINARY" ]]; then
          local current_version latest_raw latest_version is_prerelease
          current_version=$($SINGBOX_BINARY version | head -n 1 | sed 's/^sing-box version //')
          echo ">>> 检测当前 Sing-Box 版本: $current_version"

          latest_raw=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest)
          if [[ -z "$latest_raw" ]]; then
            warning_msg "无法从 GitHub API 获取最新版本信息，请检查网络连接。"
            read -n 1 -s -r -p "按任意键返回主菜单..."
            continue
          fi

          latest_version=$(echo "$latest_raw" | jq -r '.tag_name // empty' | sed 's/^v//')
          if [[ -z "$latest_version" ]]; then
            warning_msg "无法提取最新版本信息，请手动访问 sing-box releases 检查。"
            read -n 1 -s -r -p "按任意键返回主菜单..."
            continue
          fi

          echo ">>> 检测 GitHub 最新 Sing-Box 版本: $latest_version"
          is_prerelease=$(echo "$latest_raw" | jq -r '.prerelease // false')
          if [[ "$is_prerelease" == "true" ]]; then
            warning_msg "注意：最新版本 $latest_version 是预发布版 (beta/alpha)，可能不稳定。"
          fi

          if [[ "$current_version" != "$latest_version" ]]; then
            echo ">>> 检测到新版本 $latest_version，执行更新..."
            install_singbox_core
          else
            success_msg "当前 Sing-Box 已是最新版本 ($current_version)。"
            read -p "按 Enter 返回主菜单，或输入 'r' 强制重装最新稳定版: " reinstall_choice
            if [[ "${reinstall_choice,,}" == "r" ]]; then
              echo ">>> 强制重装 Sing-Box 最新稳定版..."
              install_singbox_core
            fi
          fi
        else
          echo ">>> 未检测到 Sing-Box 安装，执行首次安装..."
          install_singbox_core
        fi
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      6)
        [[ -f "$CONFIG_PATH" ]] || error_exit "请先安装。"
        manage_service
        ;;
      7) change_reality_domain; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
      8)
        if command -v warp &>/dev/null; then
          warp
        else
          error_exit "未检测到 warp 命令，请先安装 WARP。"
        fi
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      9) update_script; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
      10)
        echo "正在检查并修复出站状态..."
        restore_direct_outbound
        sleep 1
        if [[ -f "$INFO_PATH_VRV" ]]; then
          show_summary "$INFO_PATH_VRV"
        elif [[ -f "$INFO_PATH_VRVW" ]]; then
          show_summary "$INFO_PATH_VRVW"
        fi
        read -n 1 -s -r -p "按任意键返回主菜单..."
        ;;
      11) uninstall_vrvw; exit 0 ;;
      12) regenerate_config_keep_domain ;;
      0) exit 0 ;;
      *) echo -e "\n${RED}✗ 无效选项。${NC}"; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
    esac
  done
}

# ==================== 启动入口 ====================
check_root
check_dependencies
main_menu
