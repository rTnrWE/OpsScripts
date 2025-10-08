#!/bin/bash

#====================================================================================
# vwaw.sh - VLESS+WS+ArgoTunnel+WireProxy Smart Modular Deployer (v2.4 - Automated Tunnel Naming)
#
#   Description: An intelligent, stateful, and fault-tolerant deployment and
#                management tool for the VWAW proxy solution. This version
#                features automated Cloudflare Tunnel naming based on the domain.
#   Usage:
#   wget --no-check-certificate "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Xray-VWATW/vwaw.sh" -O vwaw.sh && chmod +x vwaw.sh && ./vwaw.sh
#
#====================================================================================

# --- Script Configuration ---
readonly SCRIPT_VERSION="2.4"
readonly SCRIPT_URL="https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Xray-VWATW/vwaw.sh"
readonly XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
readonly CLOUDFLARED_CONFIG_DIR="/etc/cloudflared"
readonly CLOUDFLARED_CONFIG_PATH="${CLOUDFLARED_CONFIG_DIR}/config.yml"
readonly WARP_SCRIPT_PATH="/etc/wireguard/menu.sh"
# TUNNEL_NAME is now dynamically determined and loaded from config

# --- Colors for Output ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# --- State Variables ---
STATE_XRAY_INSTALLED=false; STATE_XRAY_CONFIG_VALID=false; STATE_CLOUDFLARED_INSTALLED=false; STATE_TUNNEL_CONFIG_VALID=false; STATE_WIREPROXY_INSTALLED=false; STATE_XRAY_SERVICE_RUNNING=false; STATE_CLOUDFLARED_SERVICE_RUNNING=false; STATE_WIREPROXY_SERVICE_RUNNING=false
# Global variable for tunnel name, will be set during execution
TUNNEL_NAME=""

################################################################################
#                                                                              #
#                     FUNCTION DEFINITIONS START HERE                          #
#                                                                              #
################################################################################

# --- Utility Functions ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误: 此脚本必须以root用户权限运行。${NC}"; exit 1;
    fi
}

pause_for_user() {
    read -rp "按 [Enter] 键返回主菜单..."
}

# Function to update TUNNEL_NAME from config file if available
# This is crucial for states and uninstall options if script restarts or option 4 is chosen
load_tunnel_name_from_config() {
    if [ -f "${CLOUDFLARED_CONFIG_PATH}" ]; then
        local uuid_from_config
        uuid_from_config=$(awk '/^tunnel:/ {print $2}' "${CLOUDFLARED_CONFIG_PATH}" 2>/dev/null)
        if [ -n "$uuid_from_config" ]; then
            # Attempt to get tunnel name using cloudflared list command if UUID is found
            # Requires jq for parsing JSON output
            if command -v cloudflared &> /dev/null && command -v jq &> /dev/null; then
                local name_from_list
                name_from_list=$(cloudflared tunnel list --json 2>/dev/null | jq -r --arg uuid "$uuid_from_config" '.[] | select(.uuid == $uuid) | .name')
                if [ -n "$name_from_list" ] && [ "$name_from_list" != "null" ]; then
                    TUNNEL_NAME="$name_from_list"
                    return 0
                fi
            fi
        fi
    fi
    # If not found or cloudflared/jq not installed, keep TUNNEL_NAME empty or use a default later if needed.
    # We explicitly do not set a fallback here, as the creation process will define it.
    return 1
}


# --- State Check Functions ---
check_all_states() {
    # Reset states
    STATE_XRAY_INSTALLED=false; STATE_XRAY_CONFIG_VALID=false; STATE_CLOUDFLARED_INSTALLED=false; STATE_TUNNEL_CONFIG_VALID=false; STATE_WIREPROXY_INSTALLED=false; STATE_XRAY_SERVICE_RUNNING=false; STATE_CLOUDFLARED_SERVICE_RUNNING=false; STATE_WIREPROXY_SERVICE_RUNNING=false

    if command -v xray &> /dev/null; then STATE_XRAY_INSTALLED=true; fi
    if [ -f "${XRAY_CONFIG_PATH}" ] && xray run -test -config "${XRAY_CONFIG_PATH}" >/dev/null 2>&1; then STATE_XRAY_CONFIG_VALID=true; fi
    if systemctl is-active --quiet xray; then STATE_XRAY_SERVICE_RUNNING=true; fi

    if command -v cloudflared &> /dev/null; then STATE_CLOUDFLARED_INSTALLED=true; fi
    if [ -f "${CLOUDFLARED_CONFIG_PATH}" ] && grep -q "tunnel:" "${CLOUDFLARED_CONFIG_PATH}" && grep -q "hostname:" "${CLOUDFLARED_CONFIG_PATH}"; then
        STATE_TUNNEL_CONFIG_VALID=true
        load_tunnel_name_from_config # Try to load TUNNEL_NAME if config is valid
    fi
    if systemctl is-active --quiet cloudflared; then STATE_CLOUDFLARED_SERVICE_RUNNING=true; fi

    if [ -f "/etc/wireguard/proxy.conf" ]; then
        STATE_WIREPROXY_INSTALLED=true
        local port; port=$(awk '/^\[Socks5\]/{f=1} f && /BindAddress/{split($3, a, ":"); print a[2]; exit}' "/etc/wireguard/proxy.conf" 2>/dev/null)
        if [[ -n "$port" ]] && lsof -i:"$port" >/dev/null 2>&1; then STATE_WIREPROXY_SERVICE_RUNNING=true; fi
    fi
}

# --- Core Installation/Management Functions ---

manage_xray() {
    echo -e "\n--- Xray Core & 配置管理 ---"
    if ! ${STATE_XRAY_INSTALLED}; then
        echo ">>> 正在安装 Xray-core..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: Xray-core 安装失败。请检查网络或脚本权限。${NC}"; return 1;
        fi
    else
        echo "Xray Core 已安装。"
    fi
    if ! command -v jq &> /dev/null; then
        echo ">>> 正在安装依赖 jq 用于格式化JSON..."
        apt-get update && apt-get install -y jq
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: jq 安装失败。请手动安装 (apt-get install -y jq)。${NC}"; return 1;
        fi
    fi

    echo ">>> 正在生成/更新 Xray 配置文件..."
    local vless_uuid ws_path
    
    if ${STATE_XRAY_CONFIG_VALID}; then
        echo "检测到现有有效配置，将保留UUID和Path。"
        vless_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' ${XRAY_CONFIG_PATH})
        ws_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' ${XRAY_CONFIG_PATH})
    else
        echo "未找到有效配置或首次安装，将生成新的UUID和Path。"
        vless_uuid=$(xray uuid)
        local ws_path_uuid; ws_path_uuid=$(xray uuid)
        ws_path="/${ws_path_uuid}-ws"
    fi

    local outbound_config_json
    check_all_states # Re-check states to ensure WireProxy status is current
    if ${STATE_WIREPROXY_INSTALLED}; then
        echo "检测到WireProxy已安装，Xray出站将配置为SOCKS5代理。"
        local port; port=$(awk '/^\[Socks5\]/{f=1} f && /BindAddress/{split($3, a, ":"); print a[2]; exit}' "/etc/wireguard/proxy.conf" 2>/dev/null)
        outbound_config_json='{"protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":'${port:-40000}'}]},"tag":"proxy"},{"protocol":"freedom","tag":"direct"}'
    else
        echo "未检测到WireProxy，Xray出站将配置为直接连接。"
        outbound_config_json='{"protocol":"freedom","tag":"direct"}'
    fi

    local config_json
    config_json=$(jq -n \
        --arg vless_uuid "$vless_uuid" \
        --arg ws_path "$ws_path" \
        --argjson outbounds "[$outbound_config_json]" \
        '{
          "log": { "loglevel": "none" },
          "dns": { "servers": [ "8.8.8.8", "1.1.1.1" ] },
          "policy": { "levels": { "0": { "handshake": 8, "connIdle": 180 } } },
          "inbounds": [
            {
              "listen": "127.0.0.1",
              "port": 12861,
              "protocol": "vless",
              "settings": { "clients": [ { "id": $vless_uuid } ], "decryption": "none" },
              "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": $ws_path } }
            }
          ],
          "outbounds": $outbounds
        }')
    
    echo "${config_json}" | jq '.' > ${XRAY_CONFIG_PATH}
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: Xray 配置文件写入失败。${NC}"; return 1;
    fi
    echo "Xray 配置文件已生成/更新。"
    
    systemctl restart xray
    if ! systemctl is-active --quiet xray; then
        echo -e "${RED}错误: Xray 服务启动失败。请运行 'systemctl status xray' 查看日志。${NC}"; return 1;
    fi
    echo -e "${GREEN}Xray 服务已重启。${NC}"
}

manage_cloudflared() {
    echo -e "\n--- Cloudflare Tunnel 管理 ---"
    if ! ${STATE_CLOUDFLARED_INSTALLED}; then
        echo ">>> 正在安装 Cloudflared..."
        # Add apt-get update before installing .deb
        apt-get update
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: apt-get update 失败。请检查网络连接。${NC}"; return 1;
        fi
        curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: Cloudflared .deb 文件下载失败。请检查URL或网络连接。${NC}"; return 1;
        fi
        # Use apt-get install for better dependency handling
        apt-get install -y ./cloudflared.deb
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: Cloudflared 安装失败。请尝试 'apt-get install -f' 修复依赖，或手动安装。${NC}"; return 1;
        fi
        rm -f cloudflared.deb
    else
        echo "Cloudflared 已安装。"
    fi

    if [ -f "/root/.cloudflared/cert.pem" ]; then
        echo -e "${YELLOW}警告: 检测到旧的Cloudflared登录凭证 (/root/.cloudflared/cert.pem)。${NC}"
        read -rp "为避免错误，建议删除旧凭证并重新登录。是否立即删除? [y/N]: " del_cert
        if [[ "${del_cert}" =~ ^[yY]$ ]]; then
            rm -rf /root/.cloudflared; echo "旧凭证已删除。";
        fi
    fi

    local DOMAIN
    read -rp "请输入您准备用于隧道的域名 (例如 tunnel.yourdomain.com): " DOMAIN
    if [ -z "${DOMAIN}" ]; then echo -e "${RED}域名不能为空! 操作已取消。${NC}"; return 1; fi
    
    # --- Automated Intelligent Tunnel Naming ---
    # Replace dots with hyphens, remove leading/trailing hyphens, append -tunnel
    local generated_tunnel_name
    generated_tunnel_name=$(echo "${DOMAIN}" | sed 's/\./-/g' | sed 's/^-//' | sed 's/-$//')
    TUNNEL_NAME="${generated_tunnel_name}-tunnel" # Assign to global variable directly
    echo -e "${BLUE}将根据域名智能生成隧道名称: ${TUNNEL_NAME}${NC}"
    # --- End Automated Intelligent Tunnel Naming ---

    echo -e "\n----------------------------------------------------------------"
    echo -e " ${YELLOW}重要提示：请确保您的Cloudflare DNS后台，【没有】任何已存在的、${NC}"
    echo -e " ${YELLOW}名为 ${GREEN}${DOMAIN}${YELLOW} 的A, AAAA或CNAME记录。如果存在，请先手动删除。${NC}"
    echo -e "----------------------------------------------------------------"
    pause_for_user

    echo -e "\n----------------------------------------------------------------"
    echo -e " ${YELLOW}重要：请在下方 Cloudflared 的输出中，找到并复制那条${NC}"
    echo -e "       ${GREEN}https://dash.cloudflare.com/... ${NC}"
    echo -e " ${YELLOW}的URL链接，并用您【本地电脑的浏览器】打开它以完成授权。${NC}"
    echo -e "----------------------------------------------------------------\n"
    
    cloudflared tunnel login
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: Cloudflared 登录授权失败。请检查网络或您的Cloudflare账户。${NC}"; return 1;
    fi
    
    echo -e "\n----------------------------------------------------------------"
    read -rp " 授权成功后，请回到本终端，然后按 [Enter] 键继续..."
    
    if [ ! -f "/root/.cloudflared/cert.pem" ]; then
        echo -e "\n${RED}错误: 未检测到授权凭证文件 (cert.pem)。${NC}"
        echo -e "${YELLOW}授权似乎未成功。请重新运行此选项。${NC}"; return 1;
    fi
    echo -e "${GREEN}授权凭证检测成功。${NC}"

    echo ">>> 正在创建 Tunnel (如果 '${TUNNEL_NAME}' 已存在, 请先在Cloudflare后台手动删除)..."
    local create_output_file; create_output_file=$(mktemp)
    cloudflared tunnel create "${TUNNEL_NAME}" > "${create_output_file}" 2>&1
    
    # Debugging output for robustness (can be removed in final version if desired)
    echo -e "${YELLOW}--- cloudflared tunnel create command output ---${NC}"
    cat "${create_output_file}"
    echo -e "${YELLOW}--- End of output ---${NC}"

    # Improved error checking for tunnel creation
    if grep -qi "Error" "${create_output_file}" || ! grep -qP '[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}' "${create_output_file}"; then
        echo -e "${RED}创建 Tunnel 失败! ${NC}";
        echo -e "${YELLOW}错误信息: $(cat "${create_output_file}")${NC}";
        echo -e "${YELLOW}最常见的原因是同名隧道 '${TUNNEL_NAME}' 已存在。请在Cloudflare Zero Trust仪表盘中检查并删除旧隧道后重试。${NC}";
        rm -f "${create_output_file}"; return 1;
    fi
    
    local tunnel_uuid; tunnel_uuid=$(grep -oP '[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}' "${create_output_file}" | head -n 1); rm -f "${create_output_file}";
    if [ -z "$tunnel_uuid" ]; then
        echo -e "${RED}无法从输出中提取 Tunnel UUID。${NC}";
        echo -e "${YELLOW}Cloudflared工具的输出格式可能已更改，请检查脚本。${NC}"; return 1;
    fi
    echo "Tunnel 创建成功, UUID: ${tunnel_uuid}"
    
    mkdir -p ${CLOUDFLARED_CONFIG_DIR}
    local credentials_file="/root/.cloudflared/${tunnel_uuid}.json"
    
    printf "tunnel: %s\n" "${tunnel_uuid}" > "${CLOUDFLARED_CONFIG_PATH}"
    printf "credentials-file: %s\n" "${credentials_file}" >> "${CLOUDFLARED_CONFIG_PATH}"
    printf "ingress:\n" >> "${CLOUDFLARED_CONFIG_PATH}"
    printf "  - hostname: %s\n" "${DOMAIN}" >> "${CLOUDFLARED_CONFIG_PATH}"
    printf "    service: http://localhost:12861\n" >> "${CLOUDFLARED_CONFIG_PATH}"
    printf "  - service: http_status:404\n" >> "${CLOUDFLARED_CONFIG_PATH}"
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: Cloudflared 配置文件写入失败。${NC}"; return 1;
    fi
    echo "Cloudflared 配置文件生成成功。"

    echo ">>> 正在将域名路由到 Tunnel..."
    local route_output
    route_output=$(cloudflared tunnel route dns "${TUNNEL_NAME}" "${DOMAIN}" 2>&1) # Use dynamic TUNNEL_NAME
    if echo "${route_output}" | grep -qi "Error"; then
        echo -e "${RED}DNS路由失败! ${NC}"; echo -e "${YELLOW}错误信息: ${route_output}${NC}";
        echo -e "${YELLOW}最常见的原因是DNS记录已存在。请登录CF后台检查并删除后重试。${NC}"; return 1;
    fi
    echo "DNS路由成功。"
    
    # Install service only if not already installed, then start/enable
    if [ ! -f "/etc/systemd/system/cloudflared.service" ]; then
        cloudflared service install
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: Cloudflared systemd 服务安装失败。${NC}"; return 1;
        fi
    fi
    systemctl start cloudflared; systemctl enable cloudflared;
    if ! systemctl is-active --quiet cloudflared; then
        echo -e "${RED}错误: Cloudflared 服务启动失败。请运行 'systemctl status cloudflared' 查看日志。${NC}"; return 1;
    fi
    echo -e "${GREEN}Cloudflare Tunnel 已配置并启动。${NC}"
    
    echo ">>> 正在自动同步Xray配置以确保联动..."
    manage_xray
}

manage_wireproxy() {
    echo -e "\n--- WireProxy SOCKS5 代理管理 (fscarmen) ---"
    echo "----------------------------------------------------------------"
    echo " 即将调用 fscarmen/warp 脚本。这是一个独立的、交互式的"
    echo " 脚本，用于安装、管理和配置WireProxy。"
    echo ""
    echo " 操作完成后，脚本将自动退出。"
    echo "----------------------------------------------------------------"
    
    if [ ! -f "${WARP_SCRIPT_PATH}" ]; then
        wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh -O ${WARP_SCRIPT_PATH} && chmod +x ${WARP_SCRIPT_PATH}
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: WireProxy (fscarmen) 脚本下载失败。请检查URL或网络连接。${NC}"; return 1;
        fi
    fi
    
    # Give control to the fscarmen script
    ${WARP_SCRIPT_PATH}
    
    echo "----------------------------------------------------------------"
    echo "fscarmen脚本已退出。"
    echo "正在自动为您同步Xray配置以适应新状态..."
    # This is the key linkage: after installing/managing WireProxy, auto-update Xray config.
    manage_xray
}

display_config_info() {
    if ! ${STATE_XRAY_CONFIG_VALID} || ! ${STATE_TUNNEL_CONFIG_VALID}; then
        echo -e "\n${RED}未找到完整的核心配置文件 (Xray 或 Cloudflared)，无法显示。${NC}"; return;
    fi
    
    # Ensure TUNNEL_NAME is loaded for display if script was just run without manage_cloudflared
    if [ -z "${TUNNEL_NAME}" ]; then
        load_tunnel_name_from_config
    fi

    local vless_uuid ws_path domain port
    vless_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' ${XRAY_CONFIG_PATH})
    ws_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' ${XRAY_CONFIG_PATH})
    domain=$(grep -oP 'hostname: \K.*' ${CLOUDFLARED_CONFIG_PATH} | tr -d ' ')
    local encoded_path; encoded_path=$(echo "${ws_path}" | sed 's/\//%2F/g')

    clear
    echo "==================== VWAW Final Configuration ===================="
    echo "Tunnel Name:       ${TUNNEL_NAME:-未设置}" # Display the actual tunnel name, or "未设置" if empty
    echo "Address:           ${domain}"
    echo "Port:              443"
    echo "UUID:              ${vless_uuid}"
    echo "Network:           ws"
    echo "Path:              ${ws_path}"
    echo "TLS:               tls"
    echo "SNI / ServerName:  ${domain}"
    echo "----------------------------------------------------------------"
    echo -e "${GREEN}VLESS URL:${NC}"
    echo "vless://${vless_uuid}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&path=${encoded_path}#VWAW_${domain}"
    echo "----------------------------------------------------------------"
    echo -e "${GREEN}Xray Config File Path:${NC}"
    echo -e "${YELLOW}${XRAY_CONFIG_PATH}${NC}"
    echo "----------------------------------------------------------------"
    echo -e "${GREEN}Outbound Status:${NC}"
    if ${STATE_WIREPROXY_SERVICE_RUNNING}; then
        port=$(awk '/^\[Socks5\]/{f=1} f && /BindAddress/{split($3, a, ":"); print a[2]; exit}' "/etc/wireguard/proxy.conf" 2>/dev/null)
        echo "WireProxy: true"
        echo "SOCKS5 Port: ${port}"
        
        echo "Checking WARP IPs... (this may take a moment)"
        local ipv4; local ipv6;
        ipv4=$(curl -s -4 --max-time 8 --proxy "socks5h://127.0.0.1:${port}" https://ipv4.icanhazip.com || echo "N/A")
        ipv6=$(curl -s -6 --max-time 8 --proxy "socks5h://127.0.0.1:${port}" https://ipv6.icanhazip.com || echo "N/A")
        echo "IPv4: ${ipv4}"
        echo "IPv6: ${ipv6}"
    else
        echo "Native IP (WireProxy not active)"
    fi
    echo "================================================================"
}

check_for_updates() {
    echo -e "\n>>> 正在检查脚本更新..."
    local remote_version
    remote_version=$(wget -qO- "${SCRIPT_URL}" | grep -oP 'SCRIPT_VERSION="\K[^"]+' || echo "unknown")
    
    # Use sort -V for semantic version comparison
    if [[ "${remote_version}" != "unknown" && "$(printf '%s\n' "${SCRIPT_VERSION}" "${remote_version}" | sort -V | head -n 1)" != "${SCRIPT_VERSION}" ]]; then
        echo -e "${GREEN}发现新版本: ${remote_version} (当前版本: ${SCRIPT_VERSION})${NC}"
        read -rp "是否立即下载并运行新版本? [y/N]: " update_choice
        if [[ "${update_choice}" =~ ^[yY]$ ]]; then
            wget --no-check-certificate "${SCRIPT_URL}" -O "$0" && chmod +x "$0"
            if [ $? -ne 0 ]; then
                echo -e "${RED}错误: 脚本更新失败。请手动检查并更新。${NC}"; return 1;
            fi
            echo "脚本已更新。正在重新启动..."; exec "$0";
        fi
    else
        echo "您当前已经是最新版本。"
    fi
}

view_xray_logs() {
    echo -e "\n--- 实时查看 Xray 日志 (按 Ctrl+C 退出) ---"
    journalctl -u xray.service -f --no-pager
}

view_cloudflared_logs() {
    echo -e "\n--- 实时查看 Cloudflared 日志 (按 Ctrl+C 退出) ---"
    journalctl -u cloudflared.service -f --no-pager
}

uninstall_vwaw() {
    read -rp "警告: 此操作将卸载所有相关组件并删除配置文件。您确定吗? [y/N]: " confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        echo "卸载已取消。"; return;
    fi
    
    echo ">>> 正在停止并卸载 Xray..."
    systemctl stop xray 2>/dev/null; systemctl disable xray 2>/dev/null
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge >/dev/null 2>&1
    if [ $? -ne 0 ]; then echo -e "${YELLOW}Xray 卸载可能不完全，请手动检查。${NC}"; fi
    
    echo ">>> 正在停止并卸载 Cloudflare Tunnel..."
    systemctl stop cloudflared 2>/dev/null; systemctl disable cloudflared 2>/dev/null
    cloudflared service uninstall 2>/dev/null
    
    # Determine the tunnel name to delete
    local tunnel_to_delete="${TUNNEL_NAME}"
    if [ -z "$tunnel_to_delete" ]; then
        # If global TUNNEL_NAME is empty, try to load it from config
        load_tunnel_name_from_config
        tunnel_to_delete="${TUNNEL_NAME}"
    fi
    # As a last resort, if still empty, use a common default for uninstall attempt
    if [ -z "$tunnel_to_delete" ]; then
        echo -e "${YELLOW}警告: 无法从配置中获取 Cloudflare Tunnel 名称。将尝试删除旧的默认隧道名 'vwaw-tunnel'。${NC}"
        tunnel_to_delete="vwaw-tunnel"
    fi

    if [ -n "$tunnel_to_delete" ]; then
        echo "尝试删除 Cloudflare Tunnel: ${tunnel_to_delete}"
        # Use -f for force deletion without prompt
        cloudflared tunnel delete "${tunnel_to_delete}" -f 2>/dev/null
        if [ $? -ne 0 ]; then
            echo -e "${YELLOW}警告: Cloudflare Tunnel '${tunnel_to_delete}' 删除失败，请手动检查 Cloudflare Zero Trust 仪表盘。${NC}";
        else
            echo -e "${GREEN}Cloudflare Tunnel '${tunnel_to_delete}' 已删除。${NC}"
        fi
    else
        echo -e "${YELLOW}警告: 无法确定 Cloudflare Tunnel 名称，跳过删除隧道操作。${NC}"
    fi
    
    dpkg --purge cloudflared >/dev/null 2>&1
    if [ $? -ne 0 ]; then echo -e "${YELLOW}Cloudflared 软件包卸载可能不完全，请手动检查。${NC}"; fi
    
    echo ">>> 正在卸载 WireProxy (如果已安装)..."
    if [ -f "${WARP_SCRIPT_PATH}" ]; then
        echo "u" | ${WARP_SCRIPT_PATH} >/dev/null 2>&1
        if [ $? -ne 0 ]; then echo -e "${YELLOW}WireProxy 卸载可能不完全，请手动检查。${NC}"; fi
    fi
    
    echo ">>> 正在删除配置文件和残余目录..."
    rm -rf /usr/local/etc/xray /etc/cloudflared /etc/wireguard /root/.cloudflared
    echo -e "${GREEN}VWAW 已成功卸载。${NC}"
}

################################################################################
#                                                                              #
#                         MAIN MENU LOGIC STARTS HERE                          #
#                                                                              #
################################################################################

main_menu() {
    check_all_states
    
    local wireproxy_menu_text="[安装] WireProxy SOCKS5 代理 (fscarmen)"
    if ${STATE_WIREPROXY_INSTALLED}; then
        wireproxy_menu_text="[管理] WireProxy SOCKS5 代理 (fscarmen)"
    fi

    local current_tunnel_name_display="${TUNNEL_NAME:-未设置}" # Display actual tunnel name or "未设置"
    
    clear
    echo "-------------- VWAW 智能部署与管理 (v${SCRIPT_VERSION}) --------------"
    echo "          -- VLESS+WS+ArgoTunnel+WireProxy --"
    echo ""
    echo " [ 系统状态检查 ]"
    echo -e "   - Xray Core & 配置:        $(if ${STATE_XRAY_CONFIG_VALID}; then echo -e "${GREEN}[✓ 已完成]${NC}"; else echo -e "${RED}[✗ 未就绪]${NC}"; fi)"
    echo -e "   - Cloudflare Tunnel:         $(if ${STATE_TUNNEL_CONFIG_VALID}; then echo -e "${GREEN}[✓ 已完成]${NC}"; else echo -e "${RED}[✗ 未就绪]${NC}"; fi)"
    echo -e "     (隧道名: ${current_tunnel_name_display})"
    echo -e "   - WireProxy SOCKS5 代理:   $(if ${STATE_WIREPROXY_INSTALLED}; then echo -e "${GREEN}[✓ 已安装]${NC}"; else echo -e "${YELLOW}[- 未安装]${NC}"; fi)"
    echo ""
    echo " [ 服务运行状态 ]"
    echo -e "   - Xray Service:            $(if ${STATE_XRAY_SERVICE_RUNNING}; then echo -e "${GREEN}[✓ 运行中]${NC}"; else echo -e "${RED}[✗ 已停止]${NC}"; fi)"
    echo -e "   - Cloudflared Service:       $(if ${STATE_CLOUDFLARED_SERVICE_RUNNING}; then echo -e "${GREEN}[✓ 运行中]${NC}"; else echo -e "${RED}[✗ 已停止]${NC}"; fi)"
    echo -e "   - WireProxy Service:       $(if ${STATE_WIREPROXY_SERVICE_RUNNING}; then echo -e "${GREEN}[✓ 运行中]${NC}"; else echo -e "${RED}[✗ 已停止]${NC}"; fi)"
    echo "------------------------------------------------------------"
    echo " [ 主菜单 ]"
    echo " 1. [安装/修复] Xray Core & 配置"
    echo " 2. [安装/修复] Cloudflare Tunnel"
    echo " 3. ${wireproxy_menu_text}"
    echo " -----------------------------------------------------------"
    echo " 4. [管理] 查看最终配置信息"
    echo " 5. [管理] 重启所有服务"
    echo " 6. [管理] 卸载 VWAW"
    echo " 7. [其他] 检查脚本更新"
    echo " 8. [诊断] 实时查看 Xray 日志"
    echo " 9. [诊断] 实时查看 Cloudflared 日志"
    echo ""
    echo " 0. 退出脚本"
    echo ""
    read -rp "请输入数字 [0-9]: " choice

    case ${choice} in
        1) manage_xray; pause_for_user; main_menu;;
        2) manage_cloudflared; pause_for_user; main_menu;;
        3) manage_wireproxy; pause_for_user; main_menu;;
        4) display_config_info; pause_for_user; main_menu;;
        5)
            echo ">>> 正在重启所有服务..."
            systemctl restart xray 2>/dev/null || true
            if ! systemctl is-active --quiet xray; then echo -e "${YELLOW}Xray 服务重启失败或未运行。${NC}"; fi

            systemctl restart cloudflared 2>/dev/null || true
            if ! systemctl is-active --quiet cloudflared; then echo -e "${YELLOW}Cloudflared 服务重启失败或未运行。${NC}"; fi

            if ${STATE_WIREPROXY_INSTALLED}; then
                 # Assuming wireproxy.service is the standard systemd unit name for fscarmen's script
                 systemctl restart wireproxy.service 2>/dev/null || true
                 if ! systemctl is-active --quiet wireproxy.service; then echo -e "${YELLOW}WireProxy 服务重启失败或未运行。${NC}"; fi
            fi
            echo "所有服务已尝试重启。"
            pause_for_user; main_menu
            ;;
        6) uninstall_vwaw; main_menu;;
        7) check_for_updates; pause_for_user; main_menu;;
        8) view_xray_logs; main_menu;;
        9) view_cloudflared_logs; main_menu;;
        0) exit 0;;
        *) echo -e "${RED}无效输入...${NC}"; sleep 1; main_menu;;
    esac
}

# --- Script Entrypoint ---
check_root
main_menu
