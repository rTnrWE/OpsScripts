#!/bin/bash

#================================================================================
#
#          FILE: sing-box-deploy.sh
#
#         USAGE: bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/sing-box-deploy.sh)
#
#   DESCRIPTION: A script to install and manage sing-box with VLESS+Reality+Vision.
#
#       OPTIONS: ---
#  REQUIREMENTS: curl, openssl, jq
#          BUGS: ---
#         NOTES: ---
#        AUTHOR: Your Name
#  ORGANIZATION:
#       CREATED: $(date +'%Y-%m-%d %H:%M:%S')
#      REVISION: 1.2
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
SINGBOX_BINARY="/usr/local/bin/sing-box"

# --- Function Definitions ---

# Check if running as root
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}错误：此脚本必须以 root 权限运行。${NC}"
        exit 1
    fi
}

# Check for required dependencies and install if missing
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}检测到 'jq' 未安装，正在尝试自动安装...${NC}"
        if apt-get update && apt-get install -y jq; then
            echo -e "${GREEN}'jq' 安装成功。${NC}"
        else
            echo -e "${RED}错误：'jq' 自动安装失败。请手动安装后再运行此脚本。${NC}"
            exit 1
        fi
    fi
}


# Install sing-box core
install_singbox_core() {
    echo -e "${BLUE}>>> 正在从官方源安装/更新 sing-box 最新稳定版...${NC}"
    # The official script always fetches the latest stable version
    if ! bash <(curl -fsSL https://sing-box.app/deb-install.sh); then
        echo -e "${RED}sing-box 核心安装失败。请检查网络连接或系统环境。${NC}"
        exit 1
    fi
    echo -e "${GREEN}sing-box 核心安装成功！版本：$($SINGBOX_BINARY version | head -n 1)${NC}"
}

# Generate configuration file
generate_config() {
    echo -e "${BLUE}>>> 正在配置 VLESS + Reality + Vision...${NC}"

    # Prompt user for settings
    read -p "请输入您的服务器域名 (SNI) [必须提供，例如：my.domain.com]: " server_name
    if [[ -z "$server_name" ]]; then
        echo -e "${RED}错误：服务器域名不能为空。${NC}"
        exit 1
    fi
    
    read -p "请输入监听端口 [默认 443]: " listen_port
    listen_port=${listen_port:-443}

    read -p "请输入 Reality 握手目标域名 (dest) [默认 www.microsoft.com]: " handshake_server
    handshake_server=${handshake_server:-www.microsoft.com}

    echo -e "${YELLOW}正在生成 Reality 密钥对、UUID 和 Short ID...${NC}"

    # Generate keys and IDs
    key_pair=$($SINGBOX_BINARY generate reality-keypair)
    private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    uuid=$($SINGBOX_BINARY generate uuid)
    short_id=$(openssl rand -hex 8)

    echo -e "${GREEN}密钥和 ID 生成完毕。${NC}"

    # Create config directory if it doesn't exist
    mkdir -p /etc/sing-box

    # Write the configuration file with logging completely disabled
    tee "$CONFIG_PATH" > /dev/null <<EOF
{
  "log": {
    "disabled": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${listen_port},
      "sniff": true,
      "sniff_override_destination": true,
      "users": [
        {
          "uuid": "${uuid}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${server_name}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${handshake_server}",
            "server_port": 443
          },
          "private_key": "${private_key}",
          "short_id": [
            "${short_id}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    echo -e "${GREEN}配置文件已生成于 ${CONFIG_PATH}${NC}"
    
    # Store variables for summary
    export _uuid=${uuid}
    export _server_name=${server_name}
    export _listen_port=${listen_port}
    export _public_key=${public_key}
    export _short_id=${short_id}
    export _handshake_server=${handshake_server}
}

# Start and enable sing-box service
start_service() {
    echo -e "${BLUE}>>> 正在启动并设置 sing-box 开机自启...${NC}"
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box
    
    sleep 2 # Wait a bit for the service to start

    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}提示：sing-box 服务已成功启动并正在运行！${NC}"
    else
        echo -e "${RED}错误：sing-box 服务启动失败。请运行 'journalctl -u sing-box -n 20 --no-pager' 查看错误日志。${NC}"
        exit 1
    fi
}

# Show summary and client connection link
show_summary() {
    tag_encoded=$(printf "VLESS-Reality" | jq -s -R -r @uri)
    vless_link="vless://${_uuid}@${_server_name}:${_listen_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${_server_name}&fp=chrome&pbk=${_public_key}&sid=${_short_id}&type=tcp&headerType=none#${tag_encoded}"

    echo -e "\n=================================================="
    echo -e "${GREEN}      sing-box VLESS+Reality 安装完成！      ${NC}"
    echo -e "=================================================="
    echo -e "${YELLOW}你的配置信息:${NC}"
    echo -e "  - 服务器地址 (Address):   ${BLUE}${_server_name}${NC}"
    echo -e "  - 端口 (Port):              ${BLUE}${_listen_port}${NC}"
    echo -e "  - UUID:                   ${BLUE}${_uuid}${NC}"
    echo -e "  - Public Key:             ${BLUE}${_public_key}${NC}"
    echo -e "  - Short ID:               ${BLUE}${_short_id}${NC}"
    echo -e "  - 协议 (Flow):            ${BLUE}xtls-rprx-vision${NC}"
    echo -e "--------------------------------------------------"
    echo -e "${GREEN}客户端导入链接 (VLESS URL):${NC}"
    echo -e "${BLUE}${vless_link}${NC}"
    echo -e "--------------------------------------------------"
}

# Uninstall sing-box
uninstall() {
    echo -e "${RED}警告：此操作将停止并卸载 sing-box，并删除其配置文件。${NC}"
    read -p "你确定要继续吗? (y/N): " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        echo "卸载操作已取消。"
        exit 0
    fi

    systemctl stop sing-box
    systemctl disable sing-box >/dev/null 2>&1
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload
    rm -rf /etc/sing-box
    rm -f $SINGBOX_BINARY
    echo -e "${GREEN}sing-box 卸载完成。${NC}"
}

# Validate Reality Domain
validate_reality_domain() {
    clear
    echo -e "${BLUE}--- Reality 域名可用性与稳定性测试 ---${NC}"
    read -p "请输入你想测试的目标域名 (例如: www.microsoft.com): " domain_to_test
    if [[ -z "$domain_to_test" ]]; then echo -e "\n${RED}域名不能为空。${NC}"; sleep 2; return; fi

    echo -e "\n${YELLOW}正在对 ${domain_to_test} 进行 5 次 TLSv1.3 连接测试...${NC}"
    local success_count=0
    for i in {1..5}; do
        echo -n "第 $i/5 次测试: "
        if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 10 "https://${domain_to_test}" 2>&1 | grep -q "SSL connection using TLSv1.3"; then
            echo -e "${GREEN}成功${NC}"; ((success_count++));
        else
            echo -e "${RED}失败${NC}";
        fi
        sleep 1
    done
    echo "--------------------------------------------------"
    if [[ ${success_count} -eq 5 ]]; then echo -e "${GREEN}结论：该域名非常适合作为 Reality 目标。${NC}";
    elif [[ ${success_count} -gt 0 ]]; then echo -e "${YELLOW}结论：该域名可用，但连接可能不稳定。${NC}";
    else echo -e "${RED}结论：该域名不适合作为 Reality 目标。${NC}"; fi
    echo "--------------------------------------------------"
    read -p "按任意键返回主菜单..."
}

# --- NEW FUNCTION ---
# Check for updates and manually update sing-box
update_singbox() {
    clear
    echo -e "${BLUE}--- 检查并更新 sing-box 核心 ---${NC}"
    if [[ ! -f "$SINGBOX_BINARY" ]]; then
        echo -e "${RED}错误：sing-box 未安装，无法更新。${NC}"
        read -p "按任意键返回..."
        return
    fi

    # Get current version (e.g., 1.8.0)
    current_ver=$($SINGBOX_BINARY version | awk 'NR==1 {print $3}')

    # Get latest version from GitHub API (e.g., 1.8.1)
    echo -e "${YELLOW}正在从 GitHub 获取最新版本信息...${NC}"
    latest_ver_tag=$(curl --connect-timeout 10 -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name')
    
    if [[ -z "$latest_ver_tag" ]]; then
        echo -e "${RED}获取最新版本信息失败，请检查网络或稍后再试。${NC}"
        read -p "按任意键返回..."
        return
    fi
    latest_ver=${latest_ver_tag#v} # remove 'v' prefix

    echo -e "当前已安装版本: ${BLUE}${current_ver}${NC}"
    echo -e "GitHub 最新版本: ${GREEN}${latest_ver}${NC}"
    echo "--------------------------------------------------"

    if [[ "$current_ver" == "$latest_ver" ]]; then
        echo -e "${GREEN}恭喜！你的 sing-box 已是最新版本。${NC}"
    else
        echo -e "${YELLOW}发现新版本: ${latest_ver}${NC}"
        read -p "是否立即更新? (y/N): " confirm
        if [[ "${confirm,,}" == "y" ]]; then
            install_singbox_core # Re-run the official installer to update
            systemctl restart sing-box
            echo -e "${GREEN}sing-box 已成功更新并重启服务！${NC}"
        else
            echo "更新操作已取消。"
        fi
    fi
    read -p "按任意键返回主菜单..."
}

# Main menu
main_menu() {
    clear
    echo -e "======================================================"
    echo -e "${GREEN}      sing-box VLESS+Reality 一键部署脚本 (v1.2)      ${NC}"
    echo -e "======================================================"
    echo -e "1. ${GREEN}安装 sing-box${NC}"
    echo -e "2. ${RED}卸载 sing-box${NC}"
    echo -e "3. ${BLUE}管理 sing-box 服务${NC}"
    echo -e "4. ${YELLOW}验证 Reality 域名${NC}"
    echo -e "5. 更新 sing-box"
    echo -e "0. 退出脚本"
    echo -e "------------------------------------------------------"
    read -p "请输入你的选项 [0-5]: " choice

    case $choice in
        1) install_singbox_core; generate_config; start_service; show_summary ;;
        2) uninstall ;;
        3) manage_service; main_menu ;;
        4) validate_reality_domain; main_menu ;;
        5) update_singbox; main_menu ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入。${NC}"; sleep 2; main_menu ;;
    esac
}

# --- Script Execution ---
check_root
check_dependencies
main_menu