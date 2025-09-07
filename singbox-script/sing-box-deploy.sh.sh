#!/bin/bash

#================================================================================
#
#          FILE: sing-box-deploy.sh
#
#         USAGE: First time: bash <(curl -fsSL URL_TO_THIS_SCRIPT)
#                After install: sbd
#
#   DESCRIPTION: A comprehensive management platform for sing-box (VLESS+Reality).
#                Features self-installation, self-updating, configuration viewing,
#                and complete self-removal.
#
#       OPTIONS: ---
#  REQUIREMENTS: curl, openssl, jq
#          BUGS: ---
#         NOTES: ---
#        AUTHOR: Your Name
#  ORGANIZATION:
#       CREATED: $(date +'%Y-%m-%d %H:%M:%S')
#      REVISION: 1.7
#
#================================================================================

# --- Script Metadata and Configuration ---
SCRIPT_VERSION="1.7"
SCRIPT_URL="https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/singbox-script/sing-box-deploy.sh.sh"
INSTALL_PATH="/usr/local/sbin/sing-box-deploy.sh"
SHORTCUT_PATH="/usr/local/bin/sbd"

# --- Colors and Global Variables ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
CONFIG_PATH="/etc/sing-box/config.json"
INFO_PATH="/etc/sing-box/install_info.env" # New file to store generated info
SINGBOX_BINARY=""

# --- Core Functions ---

check_root() { [[ "$EUID" -ne 0 ]] && { echo -e "${RED}错误：此脚本必须以 root 权限运行。${NC}"; exit 1; }; }

check_dependencies() {
    for cmd in curl jq openssl; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${YELLOW}检测到 '$cmd' 未安装，正在尝试自动安装...${NC}"
            if command -v apt-get &> /dev/null; then apt-get update && apt-get install -y $cmd
            elif command -v yum &> /dev/null; then yum install -y $cmd
            elif command -v dnf &> /dev/null; then dnf install -y $cmd
            else echo -e "${RED}无法确定包管理器。请手动安装 '$cmd'。${NC}"; exit 1; fi
            if ! command -v $cmd &> /dev/null; then echo -e "${RED}错误：'$cmd' 自动安装失败。${NC}"; exit 1; fi
        fi
    done
}

install_singbox_core() {
    echo -e "${BLUE}>>> 正在安装/更新 sing-box 最新稳定版...${NC}"
    if ! bash <(curl -fsSL https://sing-box.app/deb-install.sh); then echo -e "${RED}sing-box 核心安装失败。${NC}"; exit 1; fi
    SINGBOX_BINARY=$(command -v sing-box)
    if [[ -z "$SINGBOX_BINARY" ]]; then echo -e "${RED}错误：未能找到 sing-box 可执行文件。${NC}"; exit 1; fi
    echo -e "${GREEN}sing-box 核心安装成功！版本：$($SINGBOX_BINARY version | head -n 1)${NC}"
}

internal_validate_domain() {
    local domain="$1"
    echo -n -e "${YELLOW}正在快速验证 ${domain} ... ${NC}"
    if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 5 "https://${domain}" 2>&1 | grep -q "SSL connection using TLSv1.3"; then
        echo -e "${GREEN}成功！${NC}"; return 0
    else
        echo -e "${RED}失败！${NC}"; return 1
    fi
}

generate_config() {
    echo -e "${BLUE}>>> 正在配置 VLESS + Reality + Vision...${NC}"
    local handshake_server
    while true; do
        read -p "请输入 Reality 域名 [默认 www.microsoft.com]: " handshake_server
        handshake_server=${handshake_server:-www.microsoft.com}
        internal_validate_domain "$handshake_server" && break
        read -p "是否 [R]重新输入, [F]强制使用, 或 [A]中止? (R/F/A): " choice
        case "${choice,,}" in
            f|force) echo -e "${YELLOW}警告：强制使用未通过验证的域名。${NC}"; break ;;
            a|abort) echo -e "${RED}安装已中止。${NC}"; exit 1 ;;
        esac
    done

    echo -e "${YELLOW}正在生成密钥与 ID...${NC}"
    local key_pair=$($SINGBOX_BINARY generate reality-keypair)
    local private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    local public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    local uuid=$($SINGBOX_BINARY generate uuid)
    local short_id=$(openssl rand -hex 8)
    mkdir -p /etc/sing-box

    tee "$CONFIG_PATH" > /dev/null <<EOF
{ "log": { "disabled": true }, "inbounds": [ { "type": "vless", "tag": "vless-in", "listen": "::", "listen_port": 443, "sniff": true, "sniff_override_destination": true, "users": [ { "uuid": "${uuid}", "flow": "xtls-rprx-vision" } ], "tls": { "enabled": true, "server_name": "${handshake_server}", "reality": { "enabled": true, "handshake": { "server": "${handshake_server}", "server_port": 443 }, "private_key": "${private_key}", "short_id": [ "${short_id}" ] } } } ], "outbounds": [ { "type": "direct", "tag": "direct" } ] }
EOF
    # --- NEW: Save generated info for later viewing ---
    tee "$INFO_PATH" > /dev/null <<EOF
UUID=${uuid}
PUBLIC_KEY=${public_key}
SHORT_ID=${short_id}
HANDSHAKE_SERVER=${handshake_server}
LISTEN_PORT=443
EOF
    echo -e "${GREEN}配置文件及信息已保存。${NC}"
}

start_service() {
    echo -e "${BLUE}>>> 正在启动并设置 sing-box 开机自启...${NC}"
    systemctl daemon-reload; systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
    if systemctl is-active --quiet sing-box; then echo -e "${GREEN}sing-box 服务已成功启动！${NC}"; else echo -e "${RED}错误：sing-box 服务启动失败。${NC}"; exit 1; fi
}

# --- MODIFIED: show_summary now uses printf for alignment and can be called by view_config ---
show_summary() {
    # Source info from file if it exists, otherwise use current environment variables
    if [[ -f "$INFO_PATH" ]]; then source "$INFO_PATH"; fi
    
    local server_ip=$(curl -s4 icanhazip.com || curl -s6 icanhazip.com)
    if [[ -z "$server_ip" ]]; then server_ip="[YOUR_SERVER_IP]"; fi
    
    local vless_link="vless://${UUID}@${server_ip}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${HANDSHAKE_SERVER}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-Reality"

    echo -e "\n=================================================="
    echo -e "${GREEN}      sing-box VLESS+Reality 配置信息      ${NC}"
    echo -e "=================================================="
    printf "  %-22s: %s\n" "服务器地址 (Address)" "${BLUE}${server_ip}${NC}"
    printf "  %-22s: %s\n" "端口 (Port)" "${BLUE}${LISTEN_PORT}${NC}"
    printf "  %-22s: %s\n" "UUID" "${BLUE}${UUID}${NC}"
    printf "  %-22s: %s\n" "Public Key" "${BLUE}${PUBLIC_KEY}${NC}"
    printf "  %-22s: %s\n" "Short ID" "${BLUE}${SHORT_ID}${NC}"
    printf "  %-22s: %s\n" "Reality 域名 (SNI)" "${BLUE}${HANDSHAKE_SERVER}${NC}"
    echo -e "--------------------------------------------------"
    echo -e "${GREEN}客户端导入链接 (VLESS URL):${NC}"
    echo -e "${BLUE}${vless_link}${NC}"
    echo -e "--------------------------------------------------"
}


# --- NEW/MODIFIED Management Functions ---

install_and_setup() {
    install_script
    install_singbox_core
    generate_config
    start_service
    show_summary
}

# --- NEW: View current configuration ---
view_config() {
    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e "${RED}错误：sing-box 配置文件不存在。请先安装。${NC}"; return; fi
    show_summary
}

# --- MODIFIED: Complete uninstallation including the script itself ---
uninstall_all() {
    read -p "$(echo -e ${RED}"警告：此操作将彻底卸载 sing-box 并移除本脚本。确定吗? (y/N): "${NC})" confirm
    if [[ "${confirm,,}" != "y" ]]; then echo "操作已取消。"; return; fi
    
    echo -e "${YELLOW}正在停止 sing-box 服务...${NC}"
    systemctl stop sing-box; systemctl disable sing-box >/dev/null 2>&1
    
    echo -e "${YELLOW}正在删除 sing-box 文件...${NC}"
    local bin_path=$(command -v sing-box)
    rm -rf /etc/sing-box /etc/systemd/system/sing-box.service
    if [[ -n "$bin_path" ]]; then rm -f "$bin_path"; fi
    systemctl daemon-reload
    echo -e "${GREEN}sing-box 已卸载。${NC}"

    echo -e "${YELLOW}正在移除管理脚本和快捷命令...${NC}"
    rm -f "$SHORTCUT_PATH" "$INSTALL_PATH"
    echo -e "${GREEN}脚本及快捷命令 'sbd' 已移除。${NC}"
    echo -e "${BLUE}卸载完成！${NC}"
    # The script will exit after this function.
}

# --- NEW: Functions for script self-management ---
install_script() {
    echo -e "${BLUE}>>> 正在安装管理脚本...${NC}"
    # Copy the currently executing script to the permanent location
    cp -f "$0" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    # Create or update the shortcut
    ln -sf "$INSTALL_PATH" "$SHORTCUT_PATH"
    echo -e "${GREEN}脚本已安装到 ${INSTALL_PATH}${NC}"
    echo -e "${GREEN}您现在可以随时使用 '${BLUE}sbd${GREEN}' 命令来运行此脚本。${NC}"
}

update_script() {
    echo -e "${BLUE}>>> 正在检查脚本更新...${NC}"
    local temp_script=$(mktemp)
    if ! curl -fsSL "$SCRIPT_URL" -o "$temp_script"; then
        echo -e "${RED}下载新版本脚本失败。请检查网络。${NC}"; rm "$temp_script"; return; fi
    
    if ! diff -q "$INSTALL_PATH" "$temp_script" &>/dev/null; then
        echo -e "${GREEN}发现新版本！${NC}"
        read -p "是否立即更新? (y/N): " confirm
        if [[ "${confirm,,}" == "y" ]]; then
            mv "$temp_script" "$INSTALL_PATH"
            chmod +x "$INSTALL_PATH"
            echo -e "${GREEN}脚本已更新！正在重新加载...${NC}"
            # Reload the script with new code
            exec "$INSTALL_PATH"
        else
            echo "更新已取消。"; rm "$temp_script"; fi
    else
        echo -e "${GREEN}脚本已是最新版本。${NC}"; rm "$temp_script"; fi
}

# (Other helper functions like validate_reality_domain, update_singbox, manage_service remain similar)
validate_reality_domain() {
    clear; echo -e "${BLUE}--- Reality 域名稳定性测试 ---${NC}"; read -p "请输入你想测试的目标域名: " domain_to_test
    if [[ -z "$domain_to_test" ]]; then echo -e "\n${RED}域名不能为空。${NC}"; sleep 2; return; fi
    echo -e "\n${YELLOW}正在进行 5 次 TLSv1.3 连接测试...${NC}"; local success_count=0
    for i in {1..5}; do echo -n "第 $i/5 次测试: "; if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 10 "https://${domain_to_test}" 2>&1 | grep -q "SSL connection using TLSv1.3"; then echo -e "${GREEN}成功${NC}"; ((success_count++)); else echo -e "${RED}失败${NC}"; fi; sleep 1; done
    echo "--------------------------------------------------"; if [[ ${success_count} -eq 5 ]]; then echo -e "${GREEN}结论：该域名非常适合。${NC}"; elif [[ ${success_count} -gt 0 ]]; then echo -e "${YELLOW}结论：可用但不稳定。${NC}"; else echo -e "${RED}结论：不适合。${NC}"; fi; read -p "按任意键返回..."
}

update_singbox_core() {
    # This function is now just for updating the sing-box binary
    SINGBOX_BINARY=$(command -v sing-box)
    if [[ ! -f "$SINGBOX_BINARY" ]]; then echo -e "${RED}错误：sing-box 未安装。${NC}"; read -p "按任意键返回..."; return; fi
    echo -e "${YELLOW}正在获取最新版本信息...${NC}"
    local current_ver=$($SINGBOX_BINARY version | awk 'NR==1 {print $3}')
    local latest_ver_tag=$(curl --connect-timeout 10 -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name')
    if [[ -z "$latest_ver_tag" ]]; then echo -e "${RED}获取最新版本信息失败。${NC}"; read -p "按任意键返回..."; return; fi
    local latest_ver=${latest_ver_tag#v}; echo "当前版本: ${BLUE}${current_ver}${NC} | 最新版本: ${GREEN}${latest_ver}${NC}"
    if [[ "$current_ver" != "$latest_ver" ]]; then
        read -p "发现新版本，是否更新? (y/N): " confirm
        if [[ "${confirm,,}" == "y" ]]; then install_singbox_core; systemctl restart sing-box; echo -e "${GREEN}更新成功并已重启！${NC}"; fi
    else echo -e "${GREEN}已是最新版本。${NC}"; fi; read -p "按任意键返回..."
}

# --- Main Menu Logic ---

main_menu() {
    # Check if the script is running from the installed location. If not, it's a first-time run.
    if [[ "$(realpath "$0")" != "$INSTALL_PATH" ]]; then
        install_and_setup
        exit 0
    fi
    
    clear
    echo -e "======================================================"
    echo -e "${GREEN}      sing-box 管理平台 (sbd) v${SCRIPT_VERSION}      ${NC}"
    echo -e "======================================================"
    echo -e " 1. 查看配置"
    echo -e " 2. ${YELLOW}验证 Reality 域名 (稳定性测试)${NC}"
    echo -e " 3. 管理 sing-box 服务 (暂未实现)"
    echo -e "------------------------------------------------------"
    echo -e " 8. 更新 sing-box 核心"
    echo -e " 9. ${BLUE}检查脚本更新${NC}"
    echo -e " 0. ${RED}卸载并移除一切${NC}"
    echo -e "------------------------------------------------------"
    read -p "请输入你的选项: " choice

    case $choice in
        1) view_config; read -p "按任意键返回..." ;;
        2) validate_reality_domain ;;
        # 3) manage_service ;;
        8) update_singbox_core ;;
        9) update_script ;;
        0) uninstall_all ;;
        *) echo -e "${RED}无效选项。${NC}"; sleep 1 ;;
    esac
}

# --- Script Execution ---
check_root
check_dependencies
main_menu
