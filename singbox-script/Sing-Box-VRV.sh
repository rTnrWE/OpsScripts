#!/bin/bash

#================================================================================
#
#          FILE: Sing-Box-VRV.sh
#
#         USAGE: bash <(curl -fsSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/singbox-script/Sing-Box-VRV.sh)
#                After install, use 'sbv' command (re-login may be required).
#
#   DESCRIPTION: A dedicated management platform for Sing-Box using the
#                VLESS+Reality+Vision (VRV) configuration.
#                This script is NOT intended for other protocols.
#
#       OPTIONS: ---
#  REQUIREMENTS: curl, openssl, jq
#        AUTHOR: Your Name
#  ORGANIZATION:
#       CREATED: $(date +'%Y-%m-%d %H:%M:%S')
#      REVISION: 2.0
#
#================================================================================

# --- Script Metadata and Configuration ---
SCRIPT_VERSION="2.0"
SCRIPT_URL="https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/singbox-script/Sing-Box-VRV.sh"
INSTALL_PATH="/usr/local/sbin/sing-box-vrv.sh"
SHORTCUT_PATH="/usr/local/bin/sbv"

# --- Colors and Global Variables ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
CONFIG_PATH="/etc/sing-box/config.json"
INFO_PATH="/etc/sing-box/vrv_info.env"
SINGBOX_BINARY=""

# --- Core Functions ---

check_root() { [[ "$EUID" -ne 0 ]] && { echo -e "${RED}错误：此脚本必须以 root 权限运行。${NC}"; exit 1; }; }

check_dependencies() {
    for cmd in curl jq openssl; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${YELLOW}检测到 '$cmd' 未安装，正在尝试...${NC}"
            if command -v apt-get &> /dev/null; then apt-get update >/dev/null && apt-get install -y $cmd
            elif command -v yum &> /dev/null; then yum install -y $cmd
            elif command -v dnf &> /dev/null; then dnf install -y $cmd
            else echo -e "${RED}无法确定包管理器。请手动安装 '$cmd'。${NC}"; exit 1; fi
            if ! command -v $cmd &> /dev/null; then echo -e "${RED}错误：'$cmd' 自动安装失败。${NC}"; exit 1; fi
        fi
    done
}

install_singbox_core() {
    echo -e "${BLUE}>>> 正在安装/更新 sing-box 最新稳定版...${NC}"
    if ! bash <(curl -fsSL https://sing-box.app/deb-install.sh); then echo -e "${RED}sing-box 核心安装失败。${NC}"; return 1; fi
    SINGBOX_BINARY=$(command -v sing-box)
    if [[ -z "$SINGBOX_BINARY" ]]; then echo -e "${RED}错误：未能找到 sing-box 可执行文件。${NC}"; return 1; fi
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
            a|abort) echo -e "${RED}安装已中止。${NC}"; return 1 ;;
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
    if systemctl is-active --quiet sing-box; then echo -e "${GREEN}sing-box 服务已成功启动！${NC}"; else echo -e "${RED}错误：sing-box 服务启动失败。${NC}"; return 1; fi
}

show_client_config_format() {
    if [[ ! -f "$INFO_PATH" ]]; then return; fi
    source "$INFO_PATH"
    local server_ip=$(curl -s4 icanhazip.com || curl -s6 icanhazip.com) || server_ip="[YOUR_SERVER_IP]"
    
    echo -e "--------------------------------------------------"
    echo -e "${GREEN}客户端手动配置参数:${NC}"
    printf "  %-14s: ${BLUE}%s${NC}\n" "server" "$server_ip"
    printf "  %-14s: ${BLUE}%s${NC}\n" "port" "$LISTEN_PORT"
    printf "  %-14s: ${BLUE}%s${NC}\n" "uuid" "$UUID"
    printf "  %-14s: ${BLUE}%s${NC}\n" "servername" "$HANDSHAKE_SERVER"
    printf "  %-14s: ${BLUE}%s${NC}\n" "public-key" "$PUBLIC_KEY"
    printf "  %-14s: ${BLUE}%s${NC}\n" "short-id" "$SHORT_ID"
    echo -e "--------------------------------------------------"
}

show_summary() {
    if [[ ! -f "$INFO_PATH" ]]; then echo -e "${RED}错误：未找到配置信息文件。${NC}"; return; fi
    source "$INFO_PATH"
    local server_ip=$(curl -s4 icanhazip.com || curl -s6 icanhazip.com) || server_ip="[YOUR_SERVER_IP]"
    local vless_link="vless://${UUID}@${server_ip}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${HANDSHAKE_SERVER}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Sing-Box-VRV"

    echo -e "\n=================================================="
    echo -e "${GREEN}       Sing-Box-VRV (VLESS+Reality) 配置       ${NC}"
    echo -e "=================================================="
    echo -e "${GREEN}VLESS 导入链接:${NC}"
    echo -e "${BLUE}${vless_link}${NC}"
    
    show_client_config_format
}


# --- Management Functions ---

install_vrv() {
    echo -e "${BLUE}--- 开始安装 Sing-Box-VRV ---${NC}"
    if [[ ! -f "$INSTALL_PATH" ]]; then install_script; fi
    install_singbox_core || return 1
    generate_config || return 1
    start_service || return 1
    show_summary
    echo -e "\n${GREEN}--- Sing-Box-VRV 安装成功 ---${NC}"
    echo -e "${YELLOW}管理脚本已启动，您可以直接操作。下次请使用 'sbv' 命令。${NC}"
}

change_reality_domain() {
    if [[ ! -f "$CONFIG_PATH" ]]; then echo -e "${RED}错误：尚未安装，无法更换域名。${NC}"; return; fi
    
    local new_domain
    while true; do
        read -p "请输入新的 Reality 域名: " new_domain
        [[ -z "$new_domain" ]] && { echo -e "${RED}域名不能为空。${NC}"; continue; }
        internal_validate_domain "$new_domain" && break
        read -p "是否 [R]重新输入, [F]强制使用, 或 [A]中止? (R/F/A): " choice
        case "${choice,,}" in
            f|force) echo -e "${YELLOW}警告：强制使用未通过验证的域名。${NC}"; break ;;
            a|abort) echo -e "${RED}操作已中止。${NC}"; return ;;
        esac
    done

    echo -e "${BLUE}>>> 正在更新配置文件...${NC}"
    jq --arg domain "$new_domain" '.inbounds[0].tls.server_name = $domain | .inbounds[0].tls.reality.handshake.server = $domain' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    if [[ $? -ne 0 ]]; then echo -e "${RED}错误：更新配置文件失败！${NC}"; return; fi

    sed -i "s/^HANDSHAKE_SERVER=.*/HANDSHAKE_SERVER=${new_domain}/" "$INFO_PATH"
    echo -e "${GREEN}配置文件已更新。${NC}"
    
    echo -e "${BLUE}>>> 正在重启 sing-box 服务...${NC}"
    systemctl restart sing-box
    sleep 1
    if systemctl is-active --quiet sing-box; then echo -e "${GREEN}服务重启成功！${NC}"; else echo -e "${RED}服务重启失败！${NC}"; fi
    
    show_summary
}

uninstall_vrv() {
    read -p "$(echo -e ${RED}"警告：此操作将彻底卸载 Sing-Box-VRV 及管理脚本。确定吗? (y/N): "${NC})" confirm
    if [[ "${confirm,,}" != "y" ]]; then echo "操作已取消。"; return; fi
    
    systemctl stop sing-box &>/dev/null; systemctl disable sing-box &>/dev/null
    local bin_path=$(command -v sing-box)
    rm -rf /etc/sing-box /etc/systemd/system/sing-box.service
    if [[ -n "$bin_path" ]]; then rm -f "$bin_path"; fi
    systemctl daemon-reload
    rm -f "$SHORTCUT_PATH" "$INSTALL_PATH"
    echo -e "${GREEN}Sing-Box-VRV 已被彻底移除。${NC}"
}

install_script() {
    echo -e "${BLUE}>>> 正在安装管理脚本 'sbv'...${NC}"
    cp -f "$0" "$INSTALL_PATH"; chmod +x "$INSTALL_PATH"
    ln -sf "$INSTALL_PATH" "$SHORTCUT_PATH"
    echo -e "${GREEN}脚本已安装。快捷命令: sbv${NC}"
}

update_script() {
    echo -e "${BLUE}>>> 正在检查脚本更新...${NC}"
    local temp_script=$(mktemp)
    if ! curl -fsSL "$SCRIPT_URL" -o "$temp_script"; then echo -e "${RED}下载新版本脚本失败。${NC}"; rm "$temp_script"; return; fi
    if ! diff -q "$INSTALL_PATH" "$temp_script" &>/dev/null; then
        read -p "$(echo -e ${GREEN}"发现新版本，是否更新? (y/N): "${NC})" confirm
        if [[ "${confirm,,}" == "y" ]]; then mv "$temp_script" "$INSTALL_PATH"; chmod +x "$INSTALL_PATH"; echo -e "${GREEN}脚本已更新！正在重新加载...${NC}"; exec "$INSTALL_PATH"; fi
    else echo -e "${GREEN}脚本已是最新版本。${NC}"; rm "$temp_script"; fi
}

update_singbox_core() {
    if ! command -v sing-box &> /dev/null; then echo -e "${RED}错误：sing-box 未安装。${NC}"; return; fi
    install_singbox_core && systemctl restart sing-box && echo -e "${GREEN}sing-box 核心更新并重启成功！${NC}"
}

validate_reality_domain() {
    clear; echo -e "${BLUE}--- Reality 域名稳定性测试 ---${NC}"; read -p "请输入你想测试的目标域名: " domain
    if [[ -z "$domain" ]]; then echo -e "\n${RED}域名不能为空。${NC}"; return; fi
    echo -e "\n${YELLOW}正在进行 5 次 TLSv1.3 连接测试...${NC}"; local success=0
    for i in {1..5}; do echo -n "第 $i/5 次测试: "; if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 10 "https://$domain" 2>&1 | grep -q "SSL connection using TLSv1.3"; then echo -e "${GREEN}成功${NC}"; ((success++)); else echo -e "${RED}失败${NC}"; fi; sleep 1; done
    echo "--------------------------------------------------"; if [[ $success -eq 5 ]]; then echo -e "${GREEN}结论：该域名非常适合。${NC}"; elif [[ $success -gt 0 ]]; then echo -e "${YELLOW}结论：可用但不稳定。${NC}"; else echo -e "${RED}结论：不适合。${NC}"; fi;
}


# --- Menu Logic ---
main_menu() {
    clear
    echo -e "======================================================"
    echo -e "${GREEN}      Sing-Box-VRV 管理平台 v${SCRIPT_VERSION}      ${NC}"
    echo -e "======================================================"
    if [[ ! -f "$CONFIG_PATH" ]]; then echo -e " 1. ${GREEN}安装 Sing-Box-VRV${NC}"; else echo -e " 1. ${YELLOW}重新安装 Sing-Box-VRV${NC}"; fi
    echo -e " 2. 查看配置信息"
    echo -e " 3. ${YELLOW}验证 Reality 域名${NC}"
    echo -e " 4. 更换 Reality 域名"
    echo -e "------------------------------------------------------"
    echo -e " 8. 更新 sing-box 核心"
    echo -e " 9. ${RED}彻底卸载 Sing-Box-VRV${NC}"
    echo -e " 0. ${BLUE}检查脚本更新${NC}"
    echo -e " 99. 退出脚本"
    echo -e "------------------------------------------------------"
    read -p "请输入你的选项: " choice

    case "${choice,,}" in
        1) install_vrv ;;
        2) [[ -f "$CONFIG_PATH" ]] && show_summary || echo -e "${RED}尚未安装，无配置可查看。${NC}" ;;
        3) validate_reality_domain ;;
        4) change_reality_domain ;;
        8) [[ -f "$CONFIG_PATH" ]] && update_singbox_core || echo -e "${RED}尚未安装，无法更新。${NC}" ;;
        9) uninstall_vrv; exit 0 ;;
        0) [[ -f "$INSTALL_PATH" ]] && update_script || echo -e "${RED}脚本尚未安装到系统，无法更新。${NC}" ;;
        99) exit 0 ;;
        *) echo -e "${RED}无效选项。${NC}" ;;
    esac
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

initial_setup_menu() {
    clear
    echo -e "======================================================"
    echo -e "${GREEN}    欢迎使用 Sing-Box-VRV v${SCRIPT_VERSION} 管理脚本    ${NC}"
    echo -e "======================================================"
    echo -e "这是一个专用于 VLESS+Reality+Vision 的管理平台。"
    echo
    echo -e " 1. ${GREEN}开始安装${NC}"
    echo -e " 99. 退出安装"
    echo -e "------------------------------------------------------"
    read -p "请输入你的选项: " choice
    case "$choice" in
        1) 
            install_vrv
            # After successful installation, reload the script to show the main management menu
            if [[ -f "$INSTALL_PATH" ]]; then
                exec "$INSTALL_PATH"
            fi
            ;;
        99) exit 0 ;;
        *) echo -e "${RED}无效选项。${NC}"; sleep 1; initial_setup_menu ;;
    esac
}

# --- Script Entry Point ---
check_root
check_dependencies

if [[ "$(realpath "$0")" != "$INSTALL_PATH" ]]; then
    initial_setup_menu
else
    main_menu
fi
