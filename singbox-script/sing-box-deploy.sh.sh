#!/bin/bash

#================================================================================
#
#          FILE: sing-box-deploy.sh
#
#         USAGE: bash <(curl -fsSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/singbox-script/sing-box-deploy.sh.sh)
#
#   DESCRIPTION: An intelligent script to install and manage sing-box with VLESS+Reality+Vision.
#                Features integrated domain validation, automated IP detection, and dynamic binary path finding.
#
#       OPTIONS: ---
#  REQUIREMENTS: curl, openssl, jq
#          BUGS: ---
#         NOTES: ---
#        AUTHOR: Your Name
#  ORGANIZATION:
#       CREATED: $(date +'%Y-%m-%d %H:%M:%S')
#      REVISION: 1.6
#
#================================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
CONFIG_PATH="/etc/sing-box/config.json"
SINGBOX_BINARY=""

# --- Function Definitions ---

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}错误：此脚本必须以 root 权限运行。${NC}"
        exit 1
    fi
}

check_dependencies() {
    for cmd in curl jq openssl; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${YELLOW}检测到 '$cmd' 未安装，正在尝试自动安装...${NC}"
            if command -v apt-get &> /dev/null; then
                apt-get update && apt-get install -y $cmd
            elif command -v yum &> /dev/null; then yum install -y $cmd
            elif command -v dnf &> /dev/null; then dnf install -y $cmd
            else echo -e "${RED}无法确定包管理器。请手动安装 '$cmd'。${NC}"; exit 1; fi
            if ! command -v $cmd &> /dev/null; then echo -e "${RED}错误：'$cmd' 自动安装失败。${NC}"; exit 1; fi
            echo -e "${GREEN}'$cmd' 安装成功。${NC}"
        fi
    done
}

install_singbox_core() {
    echo -e "${BLUE}>>> 正在从官方源安装/更新 sing-box 最新稳定版...${NC}"
    if ! bash <(curl -fsSL https://sing-box.app/deb-install.sh); then
        echo -e "${RED}sing-box 核心安装脚本执行失败。${NC}"; exit 1; fi
    local found_path=$(command -v sing-box)
    if [[ -z "$found_path" || ! -x "$found_path" ]]; then
        echo -e "${RED}错误：安装后未能找到 sing-box 可执行文件。${NC}"; exit 1; fi
    SINGBOX_BINARY="$found_path"
    echo -e "${GREEN}sing-box 核心安装成功！路径: ${BLUE}${SINGBOX_BINARY}${NC}"
    echo -e "${GREEN}版本：$($SINGBOX_BINARY version | head -n 1)${NC}"
}

# --- NEW: Internal function for quick validation during install ---
internal_validate_domain() {
    local domain_to_test="$1"
    echo -n -e "${YELLOW}正在快速验证 ${domain_to_test} ... ${NC}"
    if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 5 "https://${domain_to_test}" 2>&1 | grep -q "SSL connection using TLSv1.3"; then
        echo -e "${GREEN}成功！${NC}"
        return 0
    else
        echo -e "${RED}失败！${NC}"
        return 1
    fi
}

# --- MODIFIED: generate_config now includes validation loop ---
generate_config() {
    echo -e "${BLUE}>>> 正在配置 VLESS + Reality + Vision...${NC}"
    local listen_port=443
    echo -e "Reality 模式将监听标准 HTTPS 端口: ${YELLOW}${listen_port}${NC}"
    
    local handshake_server
    while true; do
        read -p "请输入 Reality 域名 [默认 www.microsoft.com]: " handshake_server
        handshake_server=${handshake_server:-www.microsoft.com}

        internal_validate_domain "$handshake_server"
        if [[ $? -eq 0 ]]; then
            break
        else
            echo -e "${YELLOW}该域名似乎不可用作 Reality 目标。${NC}"
            read -p "是否 [R]重新输入, [F]强制使用, 或 [A]中止安装? (R/F/A): " choice
            case "${choice,,}" in
                f|force)
                    echo -e "${YELLOW}警告：您选择了强制使用一个未通过验证的域名。${NC}"; break ;;
                a|abort)
                    echo -e "${RED}安装已中止。${NC}"; exit 1 ;;
                *)
                    continue ;;
            esac
        fi
    done

    echo -e "${YELLOW}正在生成 Reality 密钥对、UUID 和 Short ID...${NC}"
    key_pair=$($SINGBOX_BINARY generate reality-keypair)
    private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    uuid=$($SINGBOX_BINARY generate uuid)
    short_id=$(openssl rand -hex 8)
    echo -e "${GREEN}密钥和 ID 生成完毕。${NC}"
    mkdir -p /etc/sing-box

    tee "$CONFIG_PATH" > /dev/null <<EOF
{
  "log": { "disabled": true },
  "inbounds": [
    {
      "type": "vless", "tag": "vless-in", "listen": "::", "listen_port": ${listen_port},
      "sniff": true, "sniff_override_destination": true,
      "users": [ { "uuid": "${uuid}", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true, "server_name": "${handshake_server}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${handshake_server}", "server_port": 443 },
          "private_key": "${private_key}", "short_id": [ "${short_id}" ]
        }
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
    echo -e "${GREEN}配置文件已生成于 ${CONFIG_PATH}${NC}"
    export _uuid=${uuid}; export _listen_port=${listen_port}; export _public_key=${public_key}
    export _short_id=${short_id}; export _handshake_server=${handshake_server}
}

start_service() {
    echo -e "${BLUE}>>> 正在启动并设置 sing-box 开机自启...${NC}"
    systemctl daemon-reload; systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}提示：sing-box 服务已成功启动并正在运行！${NC}"
    else
        echo -e "${RED}错误：sing-box 服务启动失败。请运行 'journalctl -u sing-box -n 20 --no-pager' 查看错误日志。${NC}"; exit 1; fi
}

show_summary() {
    echo -e "\n${YELLOW}正在自动检测服务器公网 IP...${NC}"
    server_ip=$(curl -s4 icanhazip.com || curl -s6 icanhazip.com)
    if [[ -z "$server_ip" ]]; then server_ip="[YOUR_SERVER_IP]"; fi
    tag_encoded=$(printf "VLESS-Reality" | jq -s -R -r @uri)
    vless_link="vless://${_uuid}@${server_ip}:${_listen_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${_handshake_server}&fp=chrome&pbk=${_public_key}&sid=${_short_id}&type=tcp&headerType=none#${tag_encoded}"

    echo -e "\n=================================================="
    echo -e "${GREEN}      sing-box VLESS+Reality 安装完成！      ${NC}"
    echo -e "=================================================="
    echo -e "${YELLOW}你的配置信息:${NC}"
    echo -e "  - 服务器地址 (Address):   ${BLUE}${server_ip}${NC}"
    echo -e "  - 端口 (Port):              ${BLUE}${_listen_port}${NC}"
    echo -e "  - UUID:                   ${BLUE}${_uuid}${NC}"
    echo -e "  - Public Key:             ${BLUE}${_public_key}${NC}"
    echo -e "  - Short ID:               ${BLUE}${_short_id}${NC}"
    echo -e "  - Reality 域名 (SNI):     ${BLUE}${_handshake_server}${NC}"
    echo -e "--------------------------------------------------"
    echo -e "${GREEN}客户端导入链接 (VLESS URL):${NC}"
    echo -e "${BLUE}${vless_link}${NC}"
    echo -e "--------------------------------------------------"
}

uninstall() {
    read -p "$(echo -e ${RED}"警告：此操作将卸载 sing-box 并删除其所有配置。确定吗? (y/N): "${NC})" confirm
    if [[ "${confirm,,}" != "y" ]]; then echo "卸载操作已取消。"; exit 0; fi
    systemctl stop sing-box; systemctl disable sing-box >/dev/null 2>&1
    rm -f /etc/systemd/system/sing-box.service; systemctl daemon-reload
    local bin_path=$(command -v sing-box); rm -rf /etc/sing-box; 
    if [[ -n "$bin_path" ]]; then rm -f "$bin_path"; fi
    echo -e "${GREEN}sing-box 卸载完成。${NC}"
}

manage_service() {
    clear; echo -e "${BLUE}sing-box 服务管理菜单${NC}"; echo "------------------------"
    echo "1. 启动"; echo "2. 停止"; echo "3. 重启"; echo "4. 状态"; echo "5. 日志"; echo "0. 返回"
    read -p "请输入选项 [0-5]: " sub_choice
    case $sub_choice in
        1) systemctl start sing-box && echo "已启动" ;; 2) systemctl stop sing-box && echo "已停止" ;;
        3) systemctl restart sing-box && echo "已重启" ;; 4) systemctl status sing-box ;;
        5) journalctl -u sing-box -n 50 --no-pager ;; 0) return ;;
        *) echo "无效选项" ;;
    esac; read -p "按任意键返回..."
}

validate_reality_domain() {
    clear; echo -e "${BLUE}--- Reality 域名可用性与稳定性测试 ---${NC}"; read -p "请输入你想测试的目标域名: " domain_to_test
    if [[ -z "$domain_to_test" ]]; then echo -e "\n${RED}域名不能为空。${NC}"; sleep 2; return; fi
    echo -e "\n${YELLOW}正在对 ${domain_to_test} 进行 5 次 TLSv1.3 连接测试...${NC}"; local success_count=0
    for i in {1..5}; do
        echo -n "第 $i/5 次测试: "; if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 10 "https://${domain_to_test}" 2>&1 | grep -q "SSL connection using TLSv1.3"; then echo -e "${GREEN}成功${NC}"; ((success_count++)); else echo -e "${RED}失败${NC}"; fi; sleep 1
    done
    echo "--------------------------------------------------"; if [[ ${success_count} -eq 5 ]]; then echo -e "${GREEN}结论：该域名非常适合。${NC}"; elif [[ ${success_count} -gt 0 ]]; then echo -e "${YELLOW}结论：该域名可用但不稳定。${NC}"; else echo -e "${RED}结论：该域名不适合。${NC}"; fi
    echo "--------------------------------------------------"; read -p "按任意键返回..."
}

update_singbox() {
    if [[ -z "$SINGBOX_BINARY" ]]; then SINGBOX_BINARY=$(command -v sing-box); fi
    clear; echo -e "${BLUE}--- 检查并更新 sing-box 核心 ---${NC}"; if [[ ! -f "$SINGBOX_BINARY" ]]; then echo -e "${RED}错误：sing-box 未安装。${NC}"; read -p "按任意键返回..."; return; fi
    current_ver=$($SINGBOX_BINARY version | awk 'NR==1 {print $3}'); echo -e "${YELLOW}正在获取最新版本信息...${NC}"
    latest_ver_tag=$(curl --connect-timeout 10 -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name')
    if [[ -z "$latest_ver_tag" ]]; then echo -e "${RED}获取最新版本信息失败。${NC}"; read -p "按任意键返回..."; return; fi
    latest_ver=${latest_ver_tag#v}; echo "当前版本: ${BLUE}${current_ver}${NC} | 最新版本: ${GREEN}${latest_ver}${NC}"
    if [[ "$current_ver" == "$latest_ver" ]]; then echo -e "${GREEN}已是最新版本。${NC}"; else
        read -p "发现新版本，是否更新? (y/N): " confirm; if [[ "${confirm,,}" == "y" ]]; then
            install_singbox_core; systemctl restart sing-box; echo -e "${GREEN}更新成功并已重启服务！${NC}"; fi
    fi; read -p "按任意键返回..."
}

main_menu() {
    if [[ -z "$SINGBOX_BINARY" ]]; then SINGBOX_BINARY=$(command -v sing-box); fi
    clear
    echo -e "======================================================"
    echo -e "${GREEN}   sing-box VLESS+Reality 一键部署脚本 (v1.6)   ${NC}"
    echo -e "${GREEN}            (集成自动域名验证)            ${NC}"
    echo -e "======================================================"
    echo -e "1. ${GREEN}安装 sing-box${NC}"
    echo -e "2. ${RED}卸载 sing-box${NC}"
    echo -e "3. ${BLUE}管理 sing-box 服务${NC}"
    echo -e "4. ${YELLOW}验证 Reality 域名(稳定性测试)${NC}"
    echo -e "5. 更新 sing-box"
    echo -e "0. 退出脚本"
    echo -e "------------------------------------------------------"
    read -p "请输入你的选项 [0-5]: " choice

    case $choice in
        1) install_singbox_core; generate_config; start_service; show_summary ;;
        2) uninstall; exit 0 ;;
        3) manage_service; main_menu ;;
        4) validate_reality_domain; main_menu ;;
        5) update_singbox; main_menu ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项。${NC}"; sleep 2; main_menu ;;
    esac
}

# --- Script Execution ---
check_root
check_dependencies
main_menu
