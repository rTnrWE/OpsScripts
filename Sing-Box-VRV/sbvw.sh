#!/bin/bash

#===============================================================================
# wget -N --no-check-certificate "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbvw.sh" && chmod +x sbvw.sh && ./sbvw.sh
# Thanks: sing-box project[](https://github.com/SagerNet/sing-box), fscarmen/warp-sh project[](https://github.com/fscarmen/warp-sh)
#===============================================================================

SCRIPT_VERSION="2.2.2"
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
LAST_OUTBOUND_TYPE=""  # 记录最后使用的出站类型

trap 'echo -en "${NC}"' EXIT

# ==================== 增强的错误处理 ====================
error_exit() {
    echo -e "${RED}❌ 错误：$1${NC}"
    exit 1
}

success_msg() {
    echo -e "${GREEN}✓ $1${NC}"
}

warning_msg() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

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
                apt-get update >/dev/null 2>&1 && apt-get install -y "$cmd" dnsutils iproute2 >/dev/null 2>&1
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
    
    # 检查 WireProxy SOCKS5 端口是否实际监听
    if ! ss -tlpn 2>/dev/null | grep -q ":40043 "; then
        warning_msg "WireProxy SOCKS5 端口 40043 未被监听"
        return 1
    fi
    
    return 0
}

# ==================== 修复：恢复直连出站逻辑 ====================
restore_direct_outbound() {
    if [[ ! -f "$CONFIG_PATH" ]]; then
        warning_msg "配置文件不存在"
        return 1
    fi
    
    # 检查是否使用的是 WARP 出站
    local current_outbound_type=$(jq -r '.outbounds[0].type' "$CONFIG_PATH" 2>/dev/null)
    
    if [[ "$current_outbound_type" == "socks" ]]; then
        echo "检测到当前使用 WARP 出站，正在检查 WireProxy 状态..."
        
        if ! check_wireproxy_health; then
            warning_msg "WireProxy 已停止或不可用，自动恢复为直连出站"
            
            # 备份当前配置
            cp "$CONFIG_PATH" "${CONFIG_PATH}.warp-backup"
            
            # 更新配置为直连出站
            jq '.outbounds[0] = {
                "type": "direct",
                "tag": "direct",
                "tcp_fast_open": true
            }' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            
            if [[ $? -eq 0 ]]; then
                success_msg "配置已恢复为直连出站"
                systemctl restart sing-box
                log_action "自动恢复直连出站（WireProxy 不可用）"
                return 0
            else
                error_exit "配置更新失败"
            fi
        fi
    fi
    
    return 0
}

# ==================== TFO 状态检查 ====================
check_tfo_status() {
    local tfo_value=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "0")
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
    if [[ -z "$SINGBOX_BINARY" ]]; then
        error_exit "未能找到 sing-box 可执行文件。"
    fi
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
    cat <<EOF
======================================================
${GREEN}即将进入 fscarmen/warp 管理菜单。${NC}
您的首要任务是安装 WireProxy。
请在菜单中选择： ${GREEN}(5) 安装 WireProxy SOCKS5 代理${NC}
按照脚本提示完成所有步骤，包括可能的 WARP+ 账户设置。
完成后，此脚本将自动继续。
======================================================
EOF
    read -n 1 -s -r -p "按任意键继续..."
    bash "$warp_installer" w
    
    # 等待 WireProxy 完全启动
    sleep 3
    
    if ! systemctl is-active --quiet wireproxy; then
        error_exit "检测到 WireProxy 服务未成功启动。"
    fi
    
    # 验证 SOCKS5 端口实际监听
    if ! ss -tlpn 2>/dev/null | grep -q ":40043 "; then
        error_exit "WireProxy SOCKS5 端口 40043 未被监听。"
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
        if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 10 https://"$domain" 2>&1 | grep -q "SSL connection using TLSv1.3"; then
            success_msg "SUCCESS: $domain 第 $i 次检测通过。"
            ((success_count++))
        else
            echo -e "${RED}✗ FAILURE: $domain 第 $i 次检测失败。${NC}"
        fi
        sleep 1
    done
    [[ $success_count -ge 4 ]]
}

# ==================== 生成配置文件 ====================
generate_config() {
    local outbound_type="$1"
    echo ">>> 正在配置 VLESS + Reality + Vision..."
    local listen_addr="::"
    local listen_port=443
    local co_exist_mode=false

    # 检查端口占用
    if ss -tlpn 2>/dev/null | grep -q ":${listen_port} "; then
        co_exist_mode=true
        listen_addr="127.0.0.1"
        warning_msg "检测到 443 端口已被占用，将切换到'网站共存'模式。"
        read -p "请输入 sing-box 用于内部监听的端口 [默认 10443]: " custom_port
        listen_port=${custom_port:-10443}
    fi

    # Reality 域名配置
    local handshake_server
    while true; do
        echo -en "${GREEN}请输入 Reality 域名（示例：www.bing.com）: ${NC}"
        read handshake_server
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

    echo "正在生成密钥与 ID..."
    local key_pair=$($SINGBOX_BINARY generate reality-keypair)
    local private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    local public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    local uuid=$($SINGBOX_BINARY generate uuid)
    local short_id=$(openssl rand -hex 8)
    mkdir -p /etc/sing-box
    
    # 配置出站类型
    local outbound_config
    if [[ "$outbound_type" == "warp" ]]; then
        outbound_config='{
          "type": "socks",
          "tag": "warp-out",
          "server": "127.0.0.1",
          "server_port": 40043,
          "version": "5",
          "tcp_fast_open": true,
          "username": "",
          "password": ""
        }'
        LAST_OUTBOUND_TYPE="warp"
    else
        outbound_config='{
          "type": "direct",
          "tag": "direct",
          "tcp_fast_open": true
        }'
        LAST_OUTBOUND_TYPE="direct"
    fi

    # 生成完整的 JSON 配置
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
      }' > "$CONFIG_PATH"

    # 保存配置信息
    local info_file_path
    if [[ "$outbound_type" == "warp" ]]; then
        info_file_path="$INFO_PATH_VRVW"
    else
        info_file_path="$INFO_PATH_VRV"
    fi
    
    tee "$info_file_path" > /dev/null <<EOF
UUID=${uuid}
PUBLIC_KEY=${public_key}
SHORT_ID=${short_id}
HANDSHAKE_SERVER=${handshake_server}
OUTBOUND_TYPE=${outbound_type}
LISTEN_PORT=${listen_port}
LISTEN_ADDR=${listen_addr}
INSTALL_DATE=$(date)
EOF

    # 备份配置
    cp "$CONFIG_PATH" "$CONFIG_BACKUP_PATH"
    
    success_msg "配置生成完成"
    log_action "配置文件已生成，出站类型: $outbound_type"
    return 0
}

# ==================== 查看配置信息 ====================
show_summary() {
    local info_file="$1"
    if [[ ! -f "$info_file" ]]; then
        echo -e "${RED}配置文件不存在。${NC}"
        return 1
    fi

    source "$info_file"
    
    # 获取服务器 IP
    local server_ip=$(hostname -I | awk '{print $1}')
    
    # 从配置文件读取实际的出站类型
    local outbound_info="unknown"
    if [[ -f "$CONFIG_PATH" ]]; then
        outbound_info=$(jq -r '.outbounds[0].type' "$CONFIG_PATH" 2>/dev/null || echo "unknown")
    fi
    
    # 生成完整的 VLESS URI
    local vless_uri="vless://${UUID}@${server_ip}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&reality=1&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&sni=${HANDSHAKE_SERVER}#Reality"
    
    clear
    echo "====================================================="
    echo "    Sing-Box-(VLESS+Reality+Vision) 标准出站配置"
    echo "====================================================="
    echo "服务端配置置文件：/etc/sing-box/config.json"
    echo "-------------------------------------------------"
    echo ""
    echo -e "${GREEN}VLESS 导入链接${NC}"
    echo "${vless_uri}"
    echo "-------------------------------------------------"
    echo ""
    echo "客户端信息"
    echo ""
    echo "server        : ${server_ip}"
    echo "port          : ${LISTEN_PORT}"
    echo "uuid          : ${UUID}"
    echo "flow          : xtls-rprx-vision"
    echo "servername    : ${HANDSHAKE_SERVER}"
    echo "public-key    : ${PUBLIC_KEY}"
    echo "short-id      : ${SHORT_ID}"
    echo "-------------------------------------------------"
    echo ""
    echo -e "${GREEN}出站#Outbounds${NC}: ${outbound_info}"
    echo "-------------------------------------------------"
    echo ""
    echo "请在您自己的电脑上运行以下命令，测试您是否能到 Reality 受信的真实网站达到（越低越好）:"
    echo -e "${YELLOW}ping ${HANDSHAKE_SERVER}${NC}"
    echo "-------------------------------------------------"
    echo ""
    echo "再次运行脚本主菜单..."
    echo "./sbvw.sh"
    echo "按任意键返回主菜单..."
}

# ==================== 切换 Reality 域名 ====================
change_reality_domain() {
    if [[ ! -f "$CONFIG_PATH" ]]; then
        error_exit "配置文件不存在。"
    fi

    read -p "请输入新的 Reality 域名: " new_domain
    if [[ -z "$new_domain" ]]; then
        error_exit "域名不能为空。"
    fi

    if ! check_reality_domain "$new_domain"; then
        warning_msg "域名检测未通过，但仍然保存配置"
    fi

    jq --arg new_domain "$new_domain" '.inbounds[0].tls.reality.handshake.server = $new_domain | .inbounds[0].tls.server_name = $new_domain' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    if [[ $? -ne 0 ]]; then
        error_exit "配置更新失败！"
    fi

    # 更新信息文件
    local info_file=""
    if [[ -f "$INFO_PATH_VRV" ]]; then
        info_file="$INFO_PATH_VRV"
    elif [[ -f "$INFO_PATH_VRVW" ]]; then
        info_file="$INFO_PATH_VRVW"
    fi
    
    if [[ -n "$info_file" ]]; then
        sed -i "s/^HANDSHAKE_SERVER=.*/HANDSHAKE_SERVER=${new_domain}/" "$info_file"
    fi

    systemctl restart sing-box
    if systemctl is-active --quiet sing-box; then
        success_msg "Reality 域名已更改为: $new_domain"
        log_action "Reality 域名已更改"
    else
        error_exit "sing-box 重启失败！"
    fi
}

# ==================== 日志控制 ====================
check_and_toggle_log_status() {
    if [[ ! -f "$CONFIG_PATH" ]]; then
        error_exit "配置文件不存在。"
    fi

    local log_status=$(jq -r '.log.disabled' "$CONFIG_PATH" 2>/dev/null)
    local new_status="true"
    local status_text="关闭"
    
    if [[ "$log_status" == "true" ]]; then
        new_status="false"
        status_text="开启"
    fi

    jq ".log.disabled = $new_status" "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
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
    if [[ -f "$CONFIG_PATH" ]]; then
        local log_status=$(jq -r '.log.disabled' "$CONFIG_PATH" 2>/dev/null)
        if [[ "$log_status" != "true" ]]; then
            jq '.log.disabled = true' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            systemctl restart sing-box >/dev/null 2>&1
        fi
    fi
}

# ==================== 标准安装 ====================
install_standard() {
    clear
    echo "========================================="
    echo "    安装 Sing-Box (标准直连出站)"
    echo "========================================="
    
    check_tfo_status
    
    if ! install_singbox_core; then
        error_exit "Sing-Box 核心安装失败。"
    fi

    if ! generate_config "direct"; then
        error_exit "配置生成失败。"
    fi

    systemctl enable sing-box
    systemctl restart sing-box
    sleep 2

    if ! systemctl is-active --quiet sing-box; then
        error_exit "Sing-Box 启动失败。"
    fi

    success_msg "✅ Sing-Box 标准版安装完成！"
    show_summary "$INFO_PATH_VRV"
    log_action "标准版安装完成"
}

# ==================== WARP 版安装 ====================
install_with_warp() {
    clear
    echo "========================================="
    echo "    安装 Sing-Box + WARP (WARP出站)"
    echo "========================================="
    
    check_tfo_status
    
    if ! install_singbox_core; then
        error_exit "Sing-Box 核心安装失败。"
    fi

    if ! install_warp; then
        error_exit "WireProxy 安装失败。"
    fi

    if ! generate_config "warp"; then
        error_exit "配置生成失败。"
    fi

    systemctl enable sing-box
    systemctl restart sing-box
    sleep 2

    if ! systemctl is-active --quiet sing-box; then
        error_exit "Sing-Box 启动失败。"
    fi

    success_msg "✅ Sing-Box WARP 版安装完成！"
    show_summary "$INFO_PATH_VRVW"
    log_action "WARP 版安装完成"
}

# ==================== 升级到 WARP 版 ====================
upgrade_to_warp() {
    clear
    echo "========================================="
    echo "    升级至 WARP 版本"
    echo "========================================="
    
    if [[ ! -f "$INFO_PATH_VRV" ]]; then
        error_exit "未检测到标准版配置。"
    fi

    if ! install_warp; then
        error_exit "WireProxy 安装失败。"
    fi

    echo "正在升级配置文件..."
    
    # 获取现有的 inbound 配置
    local inbound_config=$(jq '.inbounds[0]' "$CONFIG_PATH")
    
    # 创建 WARP 出站配置
    local warp_outbound='{
      "type": "socks",
      "tag": "warp-out",
      "server": "127.0.0.1",
      "server_port": 40043,
      "version": "5",
      "tcp_fast_open": true,
      "username": "",
      "password": ""
    }'

    # 更新配置
    jq --argjson new_outbound "$warp_outbound" '.outbounds = [$new_outbound]' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    if [[ $? -ne 0 ]]; then
        error_exit "配置文件升级失败！"
    fi

    # 禁用日志
    jq '.log = {"disabled": true}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    systemctl restart sing-box
    sleep 2
    
    if [[ -f "$INFO_PATH_VRV" ]]; then
        mv "$INFO_PATH_VRV" "$INFO_PATH_VRVW"
        # 添加出站类型标记
        echo "OUTBOUND_TYPE=warp" >> "$INFO_PATH_VRVW"
    fi

    if systemctl is-active --quiet sing-box; then
        success_msg "✅ 升级成功，已切换到 WARP 出站"
        show_summary "$INFO_PATH_VRVW"
        log_action "已升级至 WARP 版本"
    else
        error_exit "sing-box 服务重启失败。"
    fi
}

# ==================== 更新脚本 ====================
update_script() {
    local temp_script_path="/root/sbvw.sh.new"
    if ! curl -fsSL "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbvw.sh" -o "$temp_script_path"; then
        warning_msg "下载新版本脚本失败。"
        rm -f "$temp_script_path"
        return 1
    fi
    
    local new_version=$(grep 'SCRIPT_VERSION="' "$temp_script_path" | awk -F '"' '{print $2}')
    if [[ -z "$new_version" ]]; then
        error_exit "未检测到新脚本版本号。"
    fi

    if [[ "$SCRIPT_VERSION" != "$new_version" ]]; then
        echo -e "${GREEN}发现新版本 v${new_version}，是否更新? (y/N): ${NC}"
        read -p "" confirm
        if [[ "${confirm,,}" != "n" ]]; then
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
        local log_status=""
        if [[ -f "$CONFIG_PATH" ]]; then
            log_status=$(jq -r '.log.disabled' "$CONFIG_PATH" 2>/dev/null)
        fi
        
        local service_status="未运行"
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
            echo " 6. 日志已关闭"
        else
            echo " 6. 日志已开启"
        fi
        echo " 0. 返回主菜单"
        echo "-------------------------"
        read -p "请输入选项: " sub_choice
        
        case $sub_choice in
            1) 
                systemctl restart sing-box
                success_msg "sing-box 服务已重启。"
                sleep 1
                ;;
            2) 
                systemctl stop sing-box
                warning_msg "sing-box 服务已停止。"
                sleep 1
                ;;
            3) 
                systemctl start sing-box
                restore_direct_outbound  # 启动时检查是否需要恢复直连
                success_msg "sing-box 服务已启动。"
                sleep 1
                ;;
            4) 
                systemctl status sing-box
                read -n 1 -s -r -p "按任意键返回服务菜单..." 
                ;;
            5) 
                view_log 
                ;;
            6) 
                check_and_toggle_log_status
                sleep 1
                ;;
            0) 
                return 
                ;;
            *) 
                echo -e "\n${RED}✗ 无效选项。${NC}"
                sleep 1 
                ;;
        esac
    done
}

# ==================== 卸载 ====================
uninstall_vrvw() {
    echo -e "${RED}警告：此操作将卸载 sing-box 及本脚本。WARP 不会被卸载。要删除配置文件吗? [Y/n]: ${NC}"
    read -p "" confirm_delete
    local keep_config=false
    if [[ "${confirm_delete,,}" == "n" ]]; then
        keep_config=true
    fi

    systemctl stop sing-box &>/dev/null
    systemctl disable sing-box &>/dev/null
    local bin_path=$(command -v sing-box)
    
    if [[ "$keep_config" == false ]]; then
        echo "正在删除 sing-box 文件 (包括配置文件)..."
        rm -rf /etc/sing-box
    else
        echo "正在删除 sing-box 核心组件 (保留配置文件)..."
    fi
    
    rm -f /etc/systemd/system/sing-box.service
    if [[ -n "$bin_path" ]]; then
        rm -f "$bin_path"
    fi
    
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
        sleep 2
        exec bash "$INSTALL_PATH"
    fi
}

# ==================== 服务状态显示 ====================
get_service_status() {
    local service_name="$1"
    local display_name="$2"
    if ! systemctl is-active --quiet "$service_name"; then
        printf "%-12s: %s\n" "$display_name" "$(echo -e ${RED}已停止${NC})"
    else
        printf "%-12s: %s\n" "$display_name" "$(echo -e ${GREEN}运行中${NC})"
    fi
}

# ==================== 主菜单 ====================
main_menu() {
    install_script_if_needed
    auto_disable_log_on_start
    restore_direct_outbound  # 启动时检查 WireProxy 并恢复直连（如需要）

    while true; do
        clear
        local is_sbv_installed=$([[ -f "$INFO_PATH_VRV" ]] && echo "true" || echo "false")
        local is_sbvw_installed=$([[ -f "$INFO_PATH_VRVW" ]] && echo "true" || echo "false")

        echo "======================================================"
        echo "  Sing-Box VRV & WARP 统一管理平台 v${SCRIPT_VERSION}  "
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
        echo "--- 维护选项 ---"
        echo " 9. 更新脚本"
        echo " 10. 检查并修复出站状态"
        echo " 11. 彻底卸载"
        echo " 0. 退出脚本"
        echo "======================================================"
        read -p "请输入你的选项: " choice

        case "${choice,,}" in
            1) 
                install_standard
                exit 0 
                ;;
            2) 
                install_with_warp
                exit 0 
                ;;
            3)
                if [[ "$is_sbv_installed" == "true" ]]; then
                    upgrade_to_warp
                    exit 0
                else
                    echo -e "\n${RED}✗ 无效选项。${NC}"
                    sleep 1
                fi
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
                SINGBOX_BINARY=$(command -v sing-box)
                if [[ -n "$SINGBOX_BINARY" ]]; then
                    current_version=$($SINGBOX_BINARY version | head -n 1)
                    echo ">>> 检测当前 Sing-Box 版本: $current_version"
                    latest_install_script=$(curl -fsSL https://sing-box.app/deb-install.sh 2>/dev/null)
                    latest_version=$(echo "$latest_install_script" | grep -oP 'sing-box_version="\K[^"]+')
                    if [[ -n "$latest_version" && "$current_version" != *"$latest_version"* ]]; then
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
                ;;
            6) 
                if [[ -f "$CONFIG_PATH" ]]; then 
                    manage_service
                else 
                    error_exit "请先安装。"
                fi 
                ;;
            7) 
                change_reality_domain 
                ;;
            8) 
                if command -v warp &>/dev/null; then 
                    warp
                else 
                    error_exit "未检测到 warp 命令，请先安装 WARP。"
                fi
                read -n 1 -s -r -p "按任意键返回主菜单..." 
                ;;
            9) 
                update_script
                read -n 1 -s -r -p "按任意键返回主菜单..." 
                ;;
            10)
                echo "正在检查并修复出站状态..."
                restore_direct_outbound
                sleep 1
                # 检查修复后显示配置信息
                if [[ -f "$INFO_PATH_VRV" ]]; then 
                    show_summary "$INFO_PATH_VRV"
                elif [[ -f "$INFO_PATH_VRVW" ]]; then 
                    show_summary "$INFO_PATH_VRVW"
                fi
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            11) 
                uninstall_vrvw
                exit 0 
                ;;
            0) 
                exit 0 
                ;;
            *) 
                echo -e "\n${RED}✗ 无效选项。${NC}"
                read -n 1 -s -r -p "按任意键返回主菜单..." 
                ;;
        esac
    done
}

# ==================== 启动入口 ====================
check_root
check_dependencies
main_menu
