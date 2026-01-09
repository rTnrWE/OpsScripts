#!/bin/bash

#===============================================================================
# wget -N --no-check-certificate "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbvs5.sh" && chmod +x sbvs5.sh && ./sbvs5.sh
# Thanks: sing-box project[](https://github.com/SagerNet/sing-box), fscarmen/warp-sh project[](https://github.com/fscarmen/warp-sh)
#===============================================================================

SCRIPT_VERSION="2.2.7"
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

# ==================== WireProxy 健康检查 ====================
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

# ==================== 判断当前出站是否为 WARP socks5 出站 ====================
is_current_outbound_warp() {
    [[ ! -f "$CONFIG_PATH" ]] && return 1
    local t tag server port
    t=$(jq -r '.outbounds[0].type // ""' "$CONFIG_PATH" 2>/dev/null)
    tag=$(jq -r '.outbounds[0].tag // ""' "$CONFIG_PATH" 2>/dev/null)
    server=$(jq -r '.outbounds[0].server // ""' "$CONFIG_PATH" 2>/dev/null)
    port=$(jq -r '.outbounds[0].server_port // 0' "$CONFIG_PATH" 2>/dev/null)

    if [[ "$t" == "socks" ]]; then
        if [[ "$tag" == "warp-out" ]]; then
            return 0
        fi
        if [[ "$server" == "127.0.0.1" && "$port" -eq 40043 ]]; then
            return 0
        fi
    fi
    return 1
}

# ==================== 判断当前出站是否为直连 ====================
is_current_outbound_direct() {
    [[ ! -f "$CONFIG_PATH" ]] && return 1
    local t
    t=$(jq -r '.outbounds[0].type // ""' "$CONFIG_PATH" 2>/dev/null)
    [[ "$t" == "direct" ]]
}

# ==================== 恢复直连出站逻辑（仅对 WARP 出站做回退检查） ====================
restore_direct_outbound() {
    if [[ ! -f "$CONFIG_PATH" ]]; then
        warning_msg "配置文件不存在"
        return 1
    fi

    if is_current_outbound_warp; then
        echo "检测到当前使用 WARP 出站，正在检查 WireProxy 状态..."

        if ! check_wireproxy_health; then
            warning_msg "WireProxy 已停止或不可用，自动恢复为直连出站"

            cp "$CONFIG_PATH" "${CONFIG_PATH}.warp-backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

            jq '.outbounds = [{
                "type": "direct",
                "tag": "direct",
                "tcp_fast_open": true
            }]' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH" || error_exit "配置更新失败"

            systemctl restart sing-box >/dev/null 2>&1 || true
            log_action "自动恢复直连出站（WireProxy 不可用）"
            success_msg "配置已恢复为直连出站"
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
    [[ -z "$SINGBOX_BINARY" ]] && error_exit "未能找到 sing-box 可执行文件。"
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
    echo " WARP 安装说明 (来自 fscarmen/warp 管理脚本) "
    echo "====================================================="
    echo "将启动 WARP 管理脚本，请在菜单中选择："
    echo "1) 安装 WARP (WireProxy 模式 / Socks5 代理)"
    echo "2) 确保 WireProxy 端口为 40043"
    echo "====================================================="
    echo ""

    bash "$warp_installer"

    if ! systemctl is-active --quiet wireproxy; then
        error_exit "WireProxy 未能启动或安装失败。"
    fi

    if ! ss -tlpn 2>/dev/null | grep -q ":40043 "; then
        error_exit "WireProxy SOCKS5 端口 40043 未被监听。"
    fi
    success_msg "WireProxy 已成功安装并运行！"
    log_action "WireProxy 安装完成"
    return 0
}

# ==================== 清除 WARP socks5 出口（用于二选一切换）====================
purge_warp_socks_outbound() {
    # 停止/禁用 wireproxy
    if systemctl list-unit-files 2>/dev/null | grep -q '^wireproxy\.service'; then
        systemctl stop wireproxy >/dev/null 2>&1 || true
        systemctl disable wireproxy >/dev/null 2>&1 || true
    fi

    # 删除 unit（尽量清理）
    if [[ -f "/etc/systemd/system/wireproxy.service" ]]; then
        rm -f /etc/systemd/system/wireproxy.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    # 如果存在 VRVW info，则转换回 VRV info（表示不再使用 warp 出口）
    if [[ -f "$INFO_PATH_VRVW" ]]; then
        mv -f "$INFO_PATH_VRVW" "$INFO_PATH_VRV" >/dev/null 2>&1 || true
    fi

    # 清理 OUTBOUND_TYPE 标记，重新写一个默认值（不影响 show_summary）
    if [[ -f "$INFO_PATH_VRV" ]]; then
        sed -i '/^OUTBOUND_TYPE=/d' "$INFO_PATH_VRV" >/dev/null 2>&1 || true
        echo "OUTBOUND_TYPE=direct" >> "$INFO_PATH_VRV" 2>/dev/null || true
    fi

    log_action "已清理 WARP Socks5 出口（wireproxy 停止/禁用/移除 unit）"
}

# ==================== 自定义 Socks5 出口（检测 warp -> 清理 -> 配置）====================
custom_socks5_outbound() {
    [[ ! -f "$CONFIG_PATH" ]] && error_exit "配置文件不存在，请先安装并生成配置。"

    echo "========================================="
    echo "          自定义 Socks5 出口"
    echo "========================================="
    echo -e "${YELLOW}说明：WARP 本质也是 Socks5 出口。此功能用于配置“自定义/第三方 Socks5 出口”。${NC}"
    echo ""

    # 检测现有出站
    if is_current_outbound_warp; then
        warning_msg "检测到当前 sing-box 出口为 WARP Socks5（warp-out / 127.0.0.1:40043）"
        echo "将先卸载/清理 WARP Socks5 出口（WireProxy），然后配置自定义 Socks5 出口..."
        purge_warp_socks_outbound
        success_msg "WARP Socks5 出口已清理"
        echo ""
    else
        if is_current_outbound_direct; then
            success_msg "当前 sing-box 出口为直连 direct，可直接配置自定义 Socks5 出口"
        else
            warning_msg "当前 sing-box 出口不是 WARP，也不是 direct，将覆盖现有出站为“自定义 Socks5 出口”"
        fi
        echo ""
    fi

    # 按你要求的输入顺序：IP -> 端口 -> 账号 -> 密码
    local socks_ip socks_port socks_user socks_pass
    read -r -p "请输入 Socks5 IP/域名，回车: " socks_ip
    [[ -z "$socks_ip" ]] && error_exit "IP/域名不能为空。"

    read -r -p "请输入端口，回车 (默认 1080): " socks_port
    socks_port=${socks_port:-1080}
    if ! [[ "$socks_port" =~ ^[0-9]+$ ]] || ((socks_port < 1 || socks_port > 65535)); then
        error_exit "端口不合法：$socks_port"
    fi

    read -r -p "请输入账号(可空)，回车: " socks_user
    read -r -s -p "请输入密码(可空)，回车: " socks_pass
    echo

    # 备份配置
    cp "$CONFIG_PATH" "${CONFIG_PATH}.custom-socks5-backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    # 生成自定义 socks5 出站
    local outbound_json
    outbound_json=$(jq -n --arg server "$socks_ip" --argjson port "$socks_port" --arg user "$socks_user" --arg pass "$socks_pass" '
        {
          "type": "socks",
          "tag": "custom-socks5-out",
          "server": $server,
          "server_port": $port,
          "version": "5",
          "tcp_fast_open": true
        }
        + (if ($user|length) > 0 then { "username": $user } else {} end)
        + (if ($pass|length) > 0 then { "password": $pass } else {} end)
    ')

    echo "$outbound_json" | jq '.' >/dev/null 2>&1 || error_exit "生成 Socks5 出站 JSON 失败。"

    # 你的脚本结构：只保留一个出站，放在 outbounds[0]
    jq --argjson new_outbound "$outbound_json" '
        .outbounds = [$new_outbound]
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH" || error_exit "写入配置失败。"

    # 统一使用 VRV info 文件来显示客户端信息（如果之前是 VRVW 也已经在 purge 中转换）
    if [[ -f "$INFO_PATH_VRV" ]]; then
        sed -i '/^OUTBOUND_TYPE=/d' "$INFO_PATH_VRV" >/dev/null 2>&1 || true
        echo "OUTBOUND_TYPE=custom_socks5" >> "$INFO_PATH_VRV" 2>/dev/null || true
    fi

    systemctl restart sing-box
    sleep 2
    if systemctl is-active --quiet sing-box; then
        success_msg "✅ 自定义 Socks5 出口已配置并生效：${socks_ip}:${socks_port}"
        log_action "配置自定义 Socks5 出口：${socks_ip}:${socks_port}"
    else
        warning_msg "配置已写入，但 sing-box 重启失败，请查看：journalctl -u sing-box -e --no-pager"
        log_action "配置自定义 Socks5 出口后 sing-box 重启失败"
    fi

    # 输出客户端配置信息 + 标识出口 Socks5 详细信息
    echo ""
    if [[ -f "$INFO_PATH_VRV" ]]; then
        show_summary "$INFO_PATH_VRV"
    elif [[ -f "$INFO_PATH_VRVW" ]]; then
        show_summary "$INFO_PATH_VRVW"
    else
        warning_msg "未找到 info 文件，无法展示客户端信息。"
    fi

    echo ""
    echo "================ 出口 Socks5 详细信息 ================"
    echo "类型(type)    : socks (SOCKS5)"
    echo "tag           : custom-socks5-out"
    echo "server        : ${socks_ip}"
    echo "server_port   : ${socks_port}"
    echo "username      : ${socks_user}"
    echo "password      : ${socks_pass}"
    echo "======================================================"
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
        read handshake_server
        handshake_server=${handshake_server:-www.bing.com}

        if check_reality_domain "$handshake_server"; then
            success_msg "最终检测：$handshake_server 适合 Reality SNI，继续安装。"
            break
        else
            echo -e "${RED}检测未通过（连续5次至少通过4次才算合格）。请更换其它 Reality 域名。${NC}"
            read -p "是否 [R]重新输入 或 [Q]退出脚本
