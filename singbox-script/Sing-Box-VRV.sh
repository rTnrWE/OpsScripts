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
#      REVISION: 1.9
#
#================================================================================

# --- Script Metadata and Configuration ---
SCRIPT_VERSION="1.9"
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

show_summary() {
    if [[ ! -f "$INFO_PATH" ]]; then echo -e "${RED}错误：未找到配置信息文件。${NC}"; return; fi
    source "$INFO_PATH"
    local server_ip=$(curl -s4 icanhazip.com || curl -s6 icanhazip.com) || server_ip="[YOUR_SERVER_IP]"
    local vless_link="vless://${UUID}@${server_ip}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${HANDSHAKE_SERVER}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Sing-Box-VRV"

    echo -e "\n=================================================="
    echo -e "${GREEN}       Sing-Box-VRV (VLESS+Reality) 配置       ${NC}"
    echo -e "=================================================="
    printf "  %-22s: ${BLUE}%s${NC}\n" "服务器地址 (Address)" "$server_ip"
    printf "  %-22s: ${BLUE}%s${NC}\n" "端口 (Port)" "$LISTEN_PORT"
    printf "  %-22s: ${BLUE}%s${NC}\n" "UUID" "$UUID"
    printf "  %-22s: ${BLUE}%s${NC}\n" "Public Key" "$PUBLIC_KEY"
    printf "  %-22s: ${BLUE}%s${NC}\n" "Short ID" "$SHORT_ID"
    printf "  %-22s: ${BLUE}%s${NC}\n" "Reality 域名 (SNI)" "$HANDSHAKE_SERVER"
    echo -e "--------------------------------------------------"
    echo -e "${GREEN}客户端导入链接:${NC}"
    echo -e "${BLUE}${vless_link}${NC}"
    echo -e "--------------------------------------------------"
}


# --- Management Functions ---

install_vrv() {
    echo -e "${BLUE}--- 开始安装 Sing-Box-VRV ---${NC}"
    install_script
    install_singbox_core || return 1
    generate_config || return 1
    start_service || return 1
    show_summary
    echo -e "\n${GREEN}--- Sing-Box-VRV 安装成功 ---${NC}"
}

uninstall_vrv() {
    read -p "$(echo -e ${RED}"警告：此操作将彻底卸载 Sing-Box-VRV 及管理脚本。确定吗? (y/N): "${NC})" confirm
    if [[ "${confirm,,}" != "y" ]]; then echo "操作已取消。"; return; fi
    
    echo -e "${YELLOW}正在停止并禁用 sing-box 服务...${NC}"
    systemctl stop sing-box &>/dev/null; systemctl disable sing-box &>/dev/null
    
    echo -e "${YELLOW}正在删除 sing-box 文件...${NC}"
    local bin_path=$(command -v sing-box)
    rm -rf /etc/sing-box /etc/systemd/system/sing-box.service
    if [[ -n "$bin_path" ]]; then rm -f "$bin_path"; fi
    systemctl daemon-reload
    echo -e "${GREEN}sing-box 已卸载。${NC}"

    echo -e "${YELLOW}正在移除 Sing-Box-VRV 管理脚本...${NC}"
    rm -f "$SHORTCUT_PATH" "$INSTALL_PATH"
    echo -e "${GREEN}管理脚本及 'sbv' 命令已移除。${NC}"
    echo -e "${BLUE}卸载完成！${NC}"
}

install_script() {
    echo -e "${BLUE}>>> 正在安装管理脚本 'sbv'...${NC}"
    cp -f "$0" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    ln -sf "$INSTALL_PATH" "$SHORTCUT_PATH"
    echo -e "${GREEN}脚本已安装。${NC}"
    echo -e "${YELLOW}提示：请重新登录 SSH 或运行 'source /etc/profile' 以使 'sbv' 命令生效。${NC}"
}

update_script() {
    echo -e "${BLUE}>>> 正在检查脚本更新...${NC}"
    local temp_script=$(mktemp)
    if ! curl -fsSL "$SCRIPT_URL" -o "$temp_script"; then
        echo -e "${RED}下载新版本脚本失败。${NC}"; rm "$temp_script"; return; fi
    
    if ! diff -q "$INSTALL_PATH" "$temp_script" &>/dev/null; then
        read -p "$(echo -e ${GREEN}"发现新版本，是否更新? (y/N): "${NC})" confirm
        if [[ "${confirm,,}" == "y" ]]; then
            mv "$temp_script" "$INSTALL_PATH"; chmod +x "$INSTALL_PATH"
            echo -e "${GREEN}脚本已更新！正在重新加载...${NC}"; exec "$INSTALL_PATH"; fi
    else
        echo -e "${GREEN}脚本已是最新版本。${NC}"; rm "$temp_script"; fi
}

update_singbox_core() {
    SINGBOX_BINARY=$(command -v sing-box)
    if [[ ! -f "$SINGBOX_BINARY" ]]; then echo -e "${RED}错误：sing-box 未安装。${NC}"; return; fi
    echo -e "${YELLOW}正在获取最新版本信息...${NC}"
    local current_ver=$($SINGBOX_BINARY version | awk 'NR==1 {print $3}')
    local latest_ver_tag=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name')
    if [[ -z "$latest_ver_tag" || "$latest_ver_tag" == "null" ]]; then echo -e "${RED}获取最新版本信息失败。${NC}"; return; fi
    local latest_ver=${latest_ver_tag#v}
    echo "当前版本: ${BLUE}${current_ver}${NC} | 最新版本: ${GREEN}${latest_ver}${NC}"
    if [[ "$current_ver" != "$latest_ver" ]]; then
        read -p "发现新版本，是否更新? (y/N): " confirm
        if [[ "${confirm,,}" == "y" ]]; then install_singbox_core && systemctl restart sing-box && echo -e "${GREEN}更新成功！${NC}"; fi
    else echo -e "${GREEN}已是最新版本。${NC}"; fi
}

validate_reality_domain() {
    # This is a standalone tool
    clear; echo -e "${BLUE}--- Reality 域名稳定性测试 ---${NC}"; read -p "请输入你想测试的目标域名: " domain_to_test
    if [[ -z "$domain_to_test" ]]; then echo -e "\n${RED}域名不能为空。${NC}"; return; fi
    echo -e "\n${YELLOW}正在进行 5 次 TLSv1.3 连接测试...${NC}"; local success_count=0
    for i in {1..5}; do echo -n "第 $i/5 次测试: "; if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 10 "https://$domain_to_test" 2>&1 | grep -q "SSL connection using TLSv1.3"; then echo -e "${GREEN}成功${NC}"; ((success_count++)); else echo -e "${RED}失败${NC}"; fi; sleep 1; done
    echo "--------------------------------------------------"; if [[ ${success_count} -eq 5 ]]; then echo -e "${GREEN}结论：该域名非常适合。${NC}"; elif [[ ${success_count} -gt 0 ]]; then echo -e "${YELLOW}结论：可用但不稳定。${NC}"; else echo -e "${RED}结论：不适合。${NC}"; fi;
}

# --- Main Menu Logic ---
main_menu() {
    clear
    echo -e "======================================================"
    echo -e "${GREEN}      Sing-Box-VRV 管理脚本 v${SCRIPT_VERSION}      ${NC}"
    echo -e "======================================================"
    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e " 1. ${GREEN}安装 Sing-Box-VRV${NC}"
    else
        echo -e " 1. ${YELLOW}重新安装 Sing-Box-VRV${NC}"
    fi
    echo -e " 2. 查看配置信息"
    echo -e " 3. ${YELLOW}验证 Reality 域名 (稳定性测试)${NC}"
    echo -e "------------------------------------------------------"
    echo -e " 8. 更新 sing-box 核心"
    echo -e " 9. ${RED}彻底卸载 Sing-Box-VRV${NC}"
    echo -e " 0. ${BLUE}检查脚本更新${NC}"
    echo -e " Q. 退出脚本"
    echo -e "------------------------------------------------------"
    read -p "请输入你的选项: " choice

    case "${choice,,}" in
        1) install_vrv ;;
        2) [[ -f "$CONFIG_PATH" ]] && show_summary || echo -e "${RED}尚未安装，无配置可查看。${NC}" ;;
        3) validate_reality_domain ;;
        8) [[ -f "$CONFIG_PATH" ]] && update_singbox_core || echo -e "${RED}尚未安装，无法更新。${NC}" ;;
        9) uninstall_vrv; exit 0 ;;
        0) [[ -f "$INSTALL_PATH" ]] && update_script || echo -e "${RED}脚本尚未安装到系统，无法更新。${NC}" ;;
        q) exit 0 ;;
        *) echo -e "${RED}无效选项。${NC}" ;;
    esac
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

# --- Script Execution ---
check_root
check_dependencies
main_menu
