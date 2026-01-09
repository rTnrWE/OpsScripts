#!/bin/bash

#===============================================================================
# wget -N --no-check-certificate "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbvs5.sh" && chmod +x sbvs5.sh && ./sbvs5.sh
# Thanks: sing-box project[](https://github.com/SagerNet/sing-box), fscarmen/warp-sh project[](https://github.com/fscarmen/warp-sh)
#===============================================================================

SCRIPT_VERSION="2.2.8"
INSTALL_PATH="/root/sbvw.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_PATH="/etc/sing-box/config.json"
INFO_PATH_VRV="/etc/sing-box/vrv_info.env"
INFO_PATH_VRVW="/etc/sing-box/vrvw_info.env"

SINGBOX_BINARY=""
WARP_SCRIPT_URL="https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"

trap 'echo -en "${NC}"' EXIT

# ==================== 基础输出/退出 ====================
error_exit() { echo -e "${RED}❌ 错误：$1${NC}"; exit 1; }
success_msg() { echo -e "${GREEN}✓ $1${NC}"; }
warning_msg() { echo -e "${YELLOW}⚠ $1${NC}"; }

log_action() {
    local action="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $action" >> /var/log/sbvw.log
}

check_root() {
    [[ "$EUID" -ne 0 ]] && error_exit "此脚本必须以 root 权限运行。"
}

check_dependencies() {
    for cmd in curl jq openssl wget ping ss; do
        if ! command -v "$cmd" &>/dev/null; then
            warning_msg "依赖 '$cmd' 未安装，正在尝试自动安装..."
            if command -v apt-get &>/dev/null; then
                apt-get update >/dev/null 2>&1
                apt-get install -y "$cmd" dnsutils iproute2 >/dev/null 2>&1
            elif command -v yum &>/dev/null; then
                yum install -y "$cmd" bind-utils iproute >/dev/null 2>&1
            elif command -v dnf &>/dev/null; then
                dnf install -y "$cmd" bind-utils iproute >/dev/null 2>&1
            else
                error_exit "无法确定包管理器。请手动安装 '$cmd'。"
            fi
            command -v "$cmd" &>/dev/null || error_exit "'$cmd' 自动安装失败。"
            success_msg "'$cmd' 安装成功"
        fi
    done
}

# ==================== WireProxy 健康检查 ====================
check_wireproxy_health() {
    systemctl is-active --quiet wireproxy || return 1
    ss -tlpn 2>/dev/null | grep -q ":40043 " || return 1
    return 0
}

# ==================== 判断当前出站 ====================
is_current_outbound_warp() {
    [[ ! -f "$CONFIG_PATH" ]] && return 1
    local t tag server port
    t=$(jq -r '.outbounds[0].type // ""' "$CONFIG_PATH" 2>/dev/null)
    tag=$(jq -r '.outbounds[0].tag // ""' "$CONFIG_PATH" 2>/dev/null)
    server=$(jq -r '.outbounds[0].server // ""' "$CONFIG_PATH" 2>/dev/null)
    port=$(jq -r '.outbounds[0].server_port // 0' "$CONFIG_PATH" 2>/dev/null)

    [[ "$t" == "socks" && ( "$tag" == "warp-out" || ( "$server" == "127.0.0.1" && "$port" -eq 40043 ) ) ]]
}

is_current_outbound_direct() {
    [[ ! -f "$CONFIG_PATH" ]] && return 1
    [[ "$(jq -r '.outbounds[0].type // ""' "$CONFIG_PATH" 2>/dev/null)" == "direct" ]]
}

# ==================== 仅在 WARP 出站时回退直连（wireproxy 不可用） ====================
restore_direct_outbound() {
    [[ ! -f "$CONFIG_PATH" ]] && return 0
    if is_current_outbound_warp; then
        if ! check_wireproxy_health; then
            warning_msg "检测到 WARP 出站，但 WireProxy 不可用，自动恢复为 direct"
            cp "$CONFIG_PATH" "${CONFIG_PATH}.warp-backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
            jq '.outbounds = [{
                "type":"direct",
                "tag":"direct",
                "tcp_fast_open":true
            }]' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH" || error_exit "回退 direct 写入失败"
            systemctl restart sing-box >/dev/null 2>&1 || true
            log_action "WireProxy 不可用，已回退 direct"
        fi
    fi
}

# ==================== TFO 检测 ====================
check_tfo_status() {
    local v
    v=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "0")
    [[ "$v" == "3" ]] && success_msg "TCP Fast Open (TFO): 已开启" || warning_msg "TCP Fast Open (TFO): 未开启（可能影响性能）"
}

# ==================== 安装 sing-box 核心 ====================
install_singbox_core() {
    echo ">>> 正在安装/更新 sing-box 最新稳定版..."
    bash <(curl -fsSL https://sing-box.app/deb-install.sh) || error_exit "sing-box 核心安装失败"
    SINGBOX_BINARY=$(command -v sing-box)
    [[ -z "$SINGBOX_BINARY" ]] && error_exit "未找到 sing-box 可执行文件"
    success_msg "sing-box 安装成功：$($SINGBOX_BINARY version | head -n 1)"
    log_action "sing-box core 安装/更新完成"
}

# ==================== 安装 WARP（调用 fscarmen 脚本） ====================
install_warp() {
    echo ">>> 正在下载并启动 WARP 管理脚本..."
    local warp_installer="/root/fscarmen-warp.sh"
    wget -N "$WARP_SCRIPT_URL" -O "$warp_installer" 2>/dev/null || error_exit "下载 WARP 管理脚本失败"
    chmod +x "$warp_installer"

    clear
    echo "====================================================="
    echo " WARP 安装说明 (来自 fscarmen/warp 管理脚本) "
    echo "====================================================="
    echo "建议选择 WireProxy 模式，并确保 SOCKS5 端口为 40043"
    echo "====================================================="
    echo ""
    bash "$warp_installer"

    systemctl is-active --quiet wireproxy || error_exit "WireProxy 未启动"
    ss -tlpn 2>/dev/null | grep -q ":40043 " || error_exit "WireProxy 40043 未监听"
    success_msg "WireProxy 已成功运行"
    log_action "WireProxy 安装完成"
}

# ==================== 清理 WARP socks5 出口（WireProxy） ====================
purge_warp_socks_outbound() {
    if systemctl list-unit-files 2>/dev/null | grep -q '^wireproxy\.service'; then
        systemctl stop wireproxy >/dev/null 2>&1 || true
        systemctl disable wireproxy >/dev/null 2>&1 || true
    fi
    if [[ -f "/etc/systemd/system/wireproxy.service" ]]; then
        rm -f /etc/systemd/system/wireproxy.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if [[ -f "$INFO_PATH_VRVW" ]]; then
        mv -f "$INFO_PATH_VRVW" "$INFO_PATH_VRV" >/dev/null 2>&1 || true
    fi
    log_action "已清理 WARP socks5（停止/禁用/移除 wireproxy unit）"
}

# ==================== Reality 域名检测 ====================
check_reality_domain() {
    local domain="$1"
    local ok=0
    echo "正在检测 ${domain} 的 Reality 可用性（连续5次）..."
    for i in {1..5}; do
        if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 10 "https://${domain}" 2>&1 | grep -q "SSL connection using TLSv1.3"; then
            success_msg "SUCCESS: ${domain} 第 ${i} 次通过"
            ((ok++))
        else
            echo -e "${RED}✗ FAILURE: ${domain} 第 ${i} 次失败${NC}"
        fi
        sleep 1
    done
    [[ $ok -ge 4 ]]
}

# ==================== 生成 sing-box 配置 ====================
generate_config() {
    local outbound_type="$1"  # direct / warp

    echo ">>> 正在配置 VLESS + Reality + Vision..."

    local listen_addr="::"
    local listen_port=443

    if ss -tlpn 2>/dev/null | grep -q ":${listen_port} "; then
        listen_addr="127.0.0.1"
        warning_msg "检测到 443 端口占用，切换“网站共存”模式"
        read -p "请输入 sing-box 内部监听端口 [默认 10443]: " custom_port
        listen_port=${custom_port:-10443}
    fi

    local handshake_server
    while true; do
        echo -en "${GREEN}请输入 Reality 域名（示例：www.bing.com）: ${NC}"
        read handshake_server
        handshake_server=${handshake_server:-www.bing.com}
        if check_reality_domain "$handshake_server"; then
            success_msg "Reality SNI 检测通过：$handshake_server"
            break
        else
            echo -e "${RED}检测未通过（至少 4/5 通过才算合格）${NC}"
            read -p "输入 R 重新输入，输入 Q 退出 (R/Q): " c
            case "${c,,}" in
                q) error_exit "已中止" ;;
                *) ;;
            esac
        fi
    done

    echo "正在生成密钥与 ID..."
    local key_pair private_key public_key uuid short_id
    key_pair=$($SINGBOX_BINARY generate reality-keypair)
    private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    public_key=$(echo "$key_pair"  | awk '/PublicKey/  {print $2}' | tr -d '"')
    uuid=$($SINGBOX_BINARY generate uuid)
    short_id=$(openssl rand -hex 8)

    mkdir -p /etc/sing-box

    local outbound_config
    if [[ "$outbound_type" == "warp" ]]; then
        outbound_config='{ "type":"socks","tag":"warp-out","server":"127.0.0.1","server_port":40043,"version":"5","tcp_fast_open":true,"username":"","password":"" }'
    else
        outbound_config='{ "type":"direct","tag":"direct","tcp_fast_open":true }'
    fi

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
                "type":"vless",
                "tag":"vless-in",
                "listen": $listen_addr,
                "listen_port": $listen_port,
                "sniff": true,
                "sniff_override_destination": true,
                "tcp_fast_open": true,
                "users":[{"uuid": $uuid, "flow":"xtls-rprx-vision"}],
                "tls":{
                  "enabled": true,
                  "server_name": $server_name,
                  "reality":{
                    "enabled": true,
                    "handshake": {"server": $server_name, "server_port": 443},
                    "private_key": $private_key,
                    "short_id": ["", $short_id]
                  }
                }
              }
            ],
            "outbounds": [ $outbound_config ]
        }' > "$CONFIG_PATH" || error_exit "写入 config.json 失败"

    local info_file_path
    if [[ "$outbound_type" == "warp" ]]; then
        info_file_path="$INFO_PATH_VRVW"
    else
        info_file_path="$INFO_PATH_VRV"
    fi

    cat > "$info_file_path" <<EOF
UUID=$uuid
PUBLIC_KEY=$public_key
PRIVATE_KEY=$private_key
SHORT_ID=$short_id
HANDSHAKE_SERVER=$handshake_server
LISTEN_ADDR=$listen_addr
LISTEN_PORT=$listen_port
EOF
}

# ==================== 展示客户端信息（含 socks 明文 user/pass） ====================
show_summary() {
    local info_file="$1"
    [[ ! -f "$info_file" ]] && error_exit "info 文件不存在：$info_file"
    source "$info_file"

    local server_ip outbound_type outbound_tag outbound_server outbound_port outbound_user outbound_pass
    server_ip=$(hostname -I | awk '{print $1}')

    outbound_type="unknown"
    outbound_tag=""
    outbound_server=""
    outbound_port=""
    outbound_user=""
    outbound_pass=""

    if [[ -f "$CONFIG_PATH" ]]; then
        outbound_type=$(jq -r '.outbounds[0].type // "unknown"' "$CONFIG_PATH" 2>/dev/null)
        outbound_tag=$(jq -r '.outbounds[0].tag // ""' "$CONFIG_PATH" 2>/dev/null)
        outbound_server=$(jq -r '.outbounds[0].server // ""' "$CONFIG_PATH" 2>/dev/null)
        outbound_port=$(jq -r '.outbounds[0].server_port // ""' "$CONFIG_PATH" 2>/dev/null)
        outbound_user=$(jq -r '.outbounds[0].username // ""' "$CONFIG_PATH" 2>/dev/null)
        outbound_pass=$(jq -r '.outbounds[0].password // ""' "$CONFIG_PATH" 2>/dev/null)
    fi

    local vless_uri="vless://${UUID}@${server_ip}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&reality=1&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&sni=${HANDSHAKE_SERVER}#Reality"

    clear
    echo "====================================================="
    echo "    Sing-Box-(VLESS+Reality+Vision) 客户端配置信息"
    echo "====================================================="
    echo "服务端配置文件：${CONFIG_PATH}"
    echo "-------------------------------------------------"
    echo ""
    echo -e "${GREEN}VLESS 导入链接${NC}"
    echo "${vless_uri}"
    echo "-------------------------------------------------"
    echo ""
    echo "客户端参数"
    echo "server        : ${server_ip}"
    echo "port          : ${LISTEN_PORT}"
    echo "uuid          : ${UUID}"
    echo "flow          : xtls-rprx-vision"
    echo "servername    : ${HANDSHAKE_SERVER}"
    echo "public-key    : ${PUBLIC_KEY}"
    echo "short-id      : ${SHORT_ID}"
    echo "-------------------------------------------------"
    echo ""
    echo -e "${GREEN}出站#Outbounds${NC}: ${outbound_type}"
    if [[ "$outbound_type" == "socks" ]]; then
        echo "tag           : ${outbound_tag}"
        echo "server        : ${outbound_server}"
        echo "server_port   : ${outbound_port}"
        echo "username      : ${outbound_user}"
        echo "password      : ${outbound_pass}"
    fi
    echo "-------------------------------------------------"
    echo ""
    echo "测试 Reality 域名延迟："
    echo -e "${YELLOW}ping ${HANDSHAKE_SERVER}${NC}"
    echo "====================================================="
}

# ==================== 更换 Reality 域名 ====================
change_reality_domain() {
    [[ ! -f "$CONFIG_PATH" ]] && error_exit "配置文件不存在"
    read -p "请输入新的 Reality 域名: " new_domain
    [[ -z "$new_domain" ]] && error_exit "域名不能为空"

    if ! check_reality_domain "$new_domain"; then
        warning_msg "域名检测未通过，但仍将写入配置"
    fi

    jq --arg d "$new_domain" \
       '.inbounds[0].tls.reality.handshake.server = $d | .inbounds[0].tls.server_name = $d' \
       "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH" || error_exit "更新配置失败"

    local info_file=""
    [[ -f "$INFO_PATH_VRV" ]] && info_file="$INFO_PATH_VRV"
    [[ -f "$INFO_PATH_VRVW" ]] && info_file="$INFO_PATH_VRVW"
    if [[ -n "$info_file" ]]; then
        sed -i "s/^HANDSHAKE_SERVER=.*/HANDSHAKE_SERVER=${new_domain}/" "$info_file"
    fi

    systemctl restart sing-box
    systemctl is-active --quiet sing-box || error_exit "sing-box 重启失败"
    success_msg "Reality 域名已更改为：$new_domain"
    log_action "Reality 域名更改：$new_domain"
}

# ==================== 日志开关 ====================
check_and_toggle_log_status() {
    [[ ! -f "$CONFIG_PATH" ]] && error_exit "配置文件不存在"
    local cur new status_text
    cur=$(jq -r '.log.disabled // true' "$CONFIG_PATH" 2>/dev/null)
    if [[ "$cur" == "true" ]]; then
        new="false"; status_text="开启"
    else
        new="true"; status_text="关闭"
    fi
    jq ".log.disabled = ${new}" "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH" || error_exit "修改日志失败"
    systemctl restart sing-box
    success_msg "日志已${status_text}"
}

view_log() {
    systemctl is-active --quiet sing-box || error_exit "sing-box 未运行"
    journalctl -u sing-box -f --no-pager
}

auto_disable_log_on_start() {
    [[ ! -f "$CONFIG_PATH" ]] && return 0
    local cur
    cur=$(jq -r '.log.disabled // true' "$CONFIG_PATH" 2>/dev/null)
    if [[ "$cur" != "true" ]]; then
        jq '.log.disabled = true' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
        systemctl restart sing-box >/dev/null 2>&1 || true
    fi
}

# ==================== 安装：直连版 ====================
install_standard() {
    clear
    echo "========================================="
    echo " 安装 Sing-Box (标准直连出站)"
    echo "========================================="
    check_tfo_status
    install_singbox_core
    generate_config "direct"
    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box
    sleep 2
    systemctl is-active --quiet sing-box || error_exit "Sing-Box 启动失败"
    success_msg "✅ 安装完成（direct）"
    show_summary "$INFO_PATH_VRV"
    log_action "安装 direct 完成"
}

# ==================== 安装：WARP 版 ====================
install_with_warp() {
    clear
    echo "========================================="
    echo " 安装 Sing-Box + WARP (WARP出站)"
    echo "========================================="
    check_tfo_status
    install_singbox_core
    install_warp
    generate_config "warp"
    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box
    sleep 2
    systemctl is-active --quiet sing-box || error_exit "Sing-Box 启动失败"
    success_msg "✅ 安装完成（WARP socks5 出站）"
    show_summary "$INFO_PATH_VRVW"
    log_action "安装 WARP 完成"
}

# ==================== 升级到 WARP 版 ====================
upgrade_to_warp() {
    clear
    echo "========================================="
    echo " 升级至 WARP 出站"
    echo "========================================="
    [[ ! -f "$CONFIG_PATH" ]] && error_exit "未检测到 sing-box 配置，请先安装"
    [[ ! -f "$INFO_PATH_VRV" ]] && error_exit "未检测到标准版 info 文件（vrv_info.env）"

    install_warp

    local warp_outbound='{ "type":"socks","tag":"warp-out","server":"127.0.0.1","server_port":40043,"version":"5","tcp_fast_open":true,"username":"","password":"" }'
    jq --argjson o "$warp_outbound" '.outbounds = [$o]' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH" || error_exit "写入 WARP 出站失败"

    jq '.log = {"disabled": true}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH" >/dev/null 2>&1 || true

    systemctl restart sing-box
    sleep 2
    systemctl is-active --quiet sing-box || error_exit "sing-box 重启失败"

    mv -f "$INFO_PATH_VRV" "$INFO_PATH_VRVW" >/dev/null 2>&1 || true
    success_msg "✅ 已升级为 WARP 出站"
    show_summary "$INFO_PATH_VRVW"
    log_action "升级到 WARP 出站"
}

# ==================== 自定义 Socks5 出口（含明文输出） ====================
custom_socks5_outbound() {
    [[ ! -f "$CONFIG_PATH" ]] && error_exit "配置文件不存在，请先安装"

    clear
    echo "========================================="
    echo "          自定义 Socks5 出口"
    echo "========================================="
    echo -e "${YELLOW}说明：WARP 本质也是 Socks5 出口。此功能配置第三方/自定义 Socks5 出口。${NC}"
    echo ""

    if is_current_outbound_warp; then
        warning_msg "检测到当前出站为 WARP socks5，将先清理 WireProxy"
        purge_warp_socks_outbound
        success_msg "WARP socks5（WireProxy）已清理"
        echo ""
    else
        if is_current_outbound_direct; then
            success_msg "当前出站为 direct，可直接配置自定义 Socks5"
        else
            warning_msg "当前出站非 WARP/non-direct，将覆盖为自定义 Socks5"
        fi
        echo ""
    fi

    local socks_ip socks_port socks_user socks_pass
    read -r -p "请输入 Socks5 IP/域名，回车: " socks_ip
    [[ -z "$socks_ip" ]] && error_exit "IP/域名不能为空"

    read -r -p "请输入端口，回车(默认 1080): " socks_port
    socks_port=${socks_port:-1080}
    if ! [[ "$socks_port" =~ ^[0-9]+$ ]] || ((socks_port < 1 || socks_port > 65535)); then
        error_exit "端口不合法：$socks_port"
    fi

    read -r -p "请输入账号(可空)，回车: " socks_user
    read -r -p "请输入密码(可空)，回车: " socks_pass

    cp "$CONFIG_PATH" "${CONFIG_PATH}.custom-socks5-backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    local outbound_json
    outbound_json=$(jq -n \
        --arg server "$socks_ip" \
        --argjson port "$socks_port" \
        --arg user "$socks_user" \
        --arg pass "$socks_pass" \
        '{
          "type":"socks",
          "tag":"custom-socks5-out",
          "server": $server,
          "server_port": $port,
          "version":"5",
          "tcp_fast_open": true
        }
        + (if ($user|length)>0 then {"username":$user} else {} end)
        + (if ($pass|length)>0 then {"password":$pass} else {} end)'
    ) || error_exit "生成出站 JSON 失败"

    jq --argjson o "$outbound_json" '.outbounds = [$o]' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH" || error_exit "写入出站失败"

    systemctl restart sing-box
    sleep 2

    if systemctl is-active --quiet sing-box; then
        success_msg "✅ 自定义 Socks5 出口已生效：${socks_ip}:${socks_port}"
        log_action "配置自定义 Socks5：${socks_ip}:${socks_port}"
    else
        warning_msg "配置已写入，但 sing-box 重启失败，请看：journalctl -u sing-box -e --no-pager"
        log_action "自定义 Socks5 后 sing-box 重启失败"
    fi

    # 输出客户端信息（优先 VRV，如存在 VRVW 也可用）
    if [[ -f "$INFO_PATH_VRV" ]]; then
        show_summary "$INFO_PATH_VRV"
    elif [[ -f "$INFO_PATH_VRVW" ]]; then
        show_summary "$INFO_PATH_VRVW"
    else
        warning_msg "未找到 info 文件，无法展示客户端信息"
    fi

    echo ""
    echo "================ 出口 Socks5 详细信息 ================"
    echo "type          : socks"
    echo "tag           : custom-socks5-out"
    echo "server        : ${socks_ip}"
    echo "server_port   : ${socks_port}"
    echo "username      : ${socks_user}"
    echo "password      : ${socks_pass}"
    echo "======================================================"
}

# ==================== 更新脚本（从原仓库拉取） ====================
update_script() {
    local temp="/root/sbvw.sh.new"
    curl -fsSL "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbvw.sh" -o "$temp" || {
        warning_msg "下载新版本脚本失败"
        rm -f "$temp"
        return 1
    }

    local new_ver
    new_ver=$(grep 'SCRIPT_VERSION="' "$temp" | awk -F '"' '{print $2}')
    [[ -z "$new_ver" ]] && error_exit "无法从新脚本中解析版本号"

    if [[ "$new_ver" != "$SCRIPT_VERSION" ]]; then
        echo -e "${GREEN}发现新版本 v${new_ver}，是否更新? (y/N): ${NC}"
        read -r c
        if [[ "${c,,}" == "y" ]]; then
            cat "$temp" > "$INSTALL_PATH"
            chmod +x "$INSTALL_PATH"
            rm -f "$temp"
            success_msg "已更新到 v${new_ver}，请重新运行 ./sbvw.sh"
            exit 0
        fi
    else
        success_msg "脚本已是最新版本（v${SCRIPT_VERSION}）"
    fi
    rm -f "$temp"
}

# ==================== 服务管理 ====================
manage_service() {
    while true; do
        clear
        local log_status="unknown"
        [[ -f "$CONFIG_PATH" ]] && log_status=$(jq -r '.log.disabled // true' "$CONFIG_PATH" 2>/dev/null)

        local service_status="${RED}已停止${NC}"
        systemctl is-active --quiet sing-box && service_status="${GREEN}运行中${NC}"

        echo "--- Sing-Box 服务管理 ---"
        echo "状态: $service_status"
        echo "-------------------------"
        echo " 1. 重启服务"
        echo " 2. 停止服务"
        echo " 3. 启动服务"
        echo " 4. 查看状态"
        echo " 5. 查看实时日志"
        echo " 6. 切换日志(当前 disabled=${log_status})"
        echo " 0. 返回主菜单"
        echo "-------------------------"
        read -p "请输入选项: " sub

        case "$sub" in
            1) systemctl restart sing-box; success_msg "已重启"; sleep 1 ;;
            2) systemctl stop sing-box; warning_msg "已停止"; sleep 1 ;;
            3) systemctl start sing-box; restore_direct_outbound; success_msg "已启动"; sleep 1 ;;
            4) systemctl status sing-box; read -n 1 -s -r -p "按任意键返回..." ;;
            5) view_log ;;
            6) check_and_toggle_log_status; sleep 1 ;;
            0) return ;;
            *) warning_msg "无效选项"; sleep 1 ;;
        esac
    done
}

# ==================== 卸载 ====================
uninstall_vrvw() {
    echo -e "${RED}警告：此操作将卸载 sing-box 及本脚本。WARP 不会被卸载。要删除配置文件吗? [Y/n]: ${NC}"
    read -r c
    local keep_config=false
    [[ "${c,,}" == "n" ]] && keep_config=true

    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true

    local bin_path
    bin_path=$(command -v sing-box)

    if [[ "$keep_config" == false ]]; then
        rm -rf /etc/sing-box
    fi

    rm -f /etc/systemd/system/sing-box.service
    [[ -n "$bin_path" ]] && rm -f "$bin_path"

    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -f "$INSTALL_PATH"

    success_msg "已卸载"
    log_action "卸载完成（keep_config=$keep_config）"
}

# ==================== 脚本复制到 /root/sbvw.sh ====================
install_script_if_needed() {
    if [[ "$(realpath "$0")" != "$INSTALL_PATH" ]]; then
        echo ">>> 首次运行，正在安装管理脚本到 ${INSTALL_PATH} ..."
        cp -f "$(realpath "$0")" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        success_msg "已安装到 ${INSTALL_PATH}，即将重新加载"
        sleep 1
        exec bash "$INSTALL_PATH"
    fi
}

get_service_status() {
    local svc="$1" name="$2"
    if systemctl is-active --quiet "$svc"; then
        printf "%-12s: %s\n" "$name" "$(echo -e ${GREEN}运行中${NC})"
    else
        printf "%-12s: %s\n" "$name" "$(echo -e ${RED}已停止${NC})"
    fi
}

# ==================== 主菜单 ====================
main_menu() {
    install_script_if_needed
    auto_disable_log_on_start
    restore_direct_outbound

    while true; do
        clear
        local is_vrv="false"
        local is_vrvw="false"
        [[ -f "$INFO_PATH_VRV" ]] && is_vrv="true"
        [[ -f "$INFO_PATH_VRVW" ]] && is_vrvw="true"

        echo "======================================================"
        echo " Sing-Box VRV & WARP 统一管理平台 v${SCRIPT_VERSION} "
        if [[ "$is_vrv" == "true" || "$is_vrvw" == "true" ]]; then
            echo "--------------------------------------------------"
            get_service_status "sing-box" "Sing-Box"
            if systemctl list-unit-files 2>/dev/null | grep -q '^wireproxy\.service'; then
                get_service_status "wireproxy" "WireProxy"
            fi
        fi
        echo "======================================================"
        echo "--- 安装选项 ---"
        echo " 1. 安装 Sing-Box (标准直连出站)"
        echo " 2. 安装 Sing-Box + WARP (WARP出站)"
        if [[ "$is_vrv" == "true" ]]; then
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
        echo " 12. 自定义Socks5出口"
        echo " 0. 退出脚本"
        echo "======================================================"

        read -p "请输入你的选项: " choice
        case "${choice,,}" in
            1) install_standard; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
            2) install_with_warp; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
            3)
                if [[ "$is_vrv" == "true" ]]; then
                    upgrade_to_warp
                else
                    warning_msg "未检测到标准版配置（vrv_info.env），无法升级"
                fi
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            4)
                if [[ -f "$INFO_PATH_VRV" ]]; then
                    show_summary "$INFO_PATH_VRV"
                elif [[ -f "$INFO_PATH_VRVW" ]]; then
                    show_summary "$INFO_PATH_VRVW"
                else
                    error_exit "请先安装"
                fi
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            5)
                install_singbox_core
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            6)
                [[ -f "$CONFIG_PATH" ]] && manage_service || error_exit "请先安装"
                ;;
            7)
                change_reality_domain
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            8)
                if command -v warp &>/dev/null; then
                    warp
                else
                    error_exit "未检测到 warp 命令，请先安装 WARP"
                fi
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            9)
                update_script
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            10)
                restore_direct_outbound
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
            12)
                custom_socks5_outbound
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            0) exit 0 ;;
            *) warning_msg "无效选项"; sleep 1 ;;
        esac
    done
}

# ==================== 启动入口 ====================
check_root
check_dependencies
main_menu
