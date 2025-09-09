#!/bin/bash

#====================================================================================
# vwaw.sh - VLESS+WS+ArgoTunnel+WireProxy Auto-Installer
#
#   Description: Automates the setup of a secure and robust proxy solution.
#   Usage:
#   wget -N --no-check-certificate "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Xray-VWATW/vwaw.sh" && chmod +x vwaw.sh && ./vwaw.sh
#
#====================================================================================

# --- Colors for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Global Variables ---
XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
CLOUDFLARED_CONFIG_DIR="/etc/cloudflared"
CLOUDFLARED_CONFIG_PATH="${CLOUDFLARED_CONFIG_DIR}/config.yml"
WARP_SCRIPT_URL="https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"
TUNNEL_NAME="vwaw-tunnel"

# --- Utility Functions ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误: 此脚本必须以root用户权限运行。${NC}"
        exit 1
    fi
}

check_os() {
    if ! grep -qs "Debian" /etc/os-release && ! grep -qs "Ubuntu" /etc/os-release; then
        echo -e "${RED}错误: 此脚本目前仅支持 Debian 或 Ubuntu 系统。${NC}"
        exit 1
    fi
}

check_dependencies() {
    echo -e "${BLUE}>>> 正在检查核心依赖...${NC}"
    local missing_deps=()
    for cmd in curl wget systemctl dpkg lsof nano; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${RED}错误: 缺少以下核心依赖: ${missing_deps[*]}${NC}"
        echo -e "${YELLOW}请尝试运行 'apt update && apt install -y ${missing_deps[*]}' 来安装它们。${NC}"
        exit 1
    fi
    echo -e "${GREEN}核心依赖检查通过。${NC}"
}

install_base_dependencies() {
    echo -e "${BLUE}>>> 正在更新软件包列表并安装基础依赖...${NC}"
    apt update && apt install -y curl wget nano lsof > /dev/null 2>&1
}

pause_for_user() {
    read -rp "按 [Enter] 键继续..."
}

# --- Core Functions ---

install_xray() {
    echo -e "${BLUE}>>> 正在安装 Xray-core...${NC}"
    if command -v xray &> /dev/null; then
        echo -e "${YELLOW}Xray 已安装，跳过。${NC}"
        return
    fi
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}Xray 安装失败，请检查网络。${NC}"
        exit 1
    fi
    echo -e "${GREEN}Xray 安装成功。${NC}"
}

configure_xray() {
    echo -e "${BLUE}>>> 正在配置 Xray...${NC}"
    VLESS_UUID=$(xray uuid)
    WS_PATH_UUID=$(xray uuid)
    WS_PATH="/${WS_PATH_UUID}-ws"

    cat << EOF > ${XRAY_CONFIG_PATH}
{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 12861,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${WS_PATH}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 40000
          }
        ]
      },
      "tag": "warp-proxy"
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
    echo -e "${GREEN}Xray 配置生成成功。${NC}"
}

install_wireproxy() {
    echo -e "${BLUE}>>> 即将安装 WireProxy (SOCKS5)...${NC}"
    wget -N ${WARP_SCRIPT_URL} -O menu.sh > /dev/null 2>&1
    chmod +x menu.sh

    echo -e "${YELLOW}----------------------------------------------------------------${NC}"
    echo -e " ${YELLOW}请选择 WireProxy 安装方式:${NC}"
    echo -e " ${GREEN}1. 全自动安装 (默认，适用于大多数用户)${NC}"
    echo -e " ${BLUE}2. 手动交互安装 (适用于WARP+账户或需要自定义的用户)${NC}"
    echo -e "${YELLOW}----------------------------------------------------------------${NC}"
    read -rp "请输入数字 [1-2] (直接按回车将选择 1): " warp_choice
    
    case ${warp_choice} in
        2)
            echo -e "${BLUE}>>> 即将进入手动安装模式，请根据提示操作...${NC}"
            echo -e "${YELLOW}请在菜单中选择与 'wireproxy' 或 'SOCKS5' 相关的选项 (通常是 13 或 w)。${NC}"
            ./menu.sh
            ;;
        *)
            echo -e "${BLUE}>>> 正在进行全自动安装...${NC}"
            echo "w" | ./menu.sh
            ;;
    esac

    if ! lsof -i:40000 > /dev/null; then
        echo -e "${RED}WireProxy SOCKS5 代理安装或启动失败。${NC}"
        echo -e "${YELLOW}建议您稍后运行主菜单中的 '打开 WARP 手动操作菜单' 进行检查和重装。${NC}"
        exit 1
    else
        echo -e "${GREEN}WireProxy SOCKS5 代理安装并启动成功。${NC}"
    fi
}

install_cloudflared() {
    echo -e "${BLUE}>>> 正在安装 Cloudflared...${NC}"
    if command -v cloudflared &> /dev/null; then
        echo -e "${YELLOW}Cloudflared 已安装，跳过。${NC}"
        return
    fi
    curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb > /dev/null 2>&1
    dpkg -i cloudflared.deb > /dev/null 2>&1
    echo -e "${GREEN}Cloudflared 安装成功。${NC}"
}

configure_cloudflared() {
    echo -e "${BLUE}>>> 正在配置 Cloudflare Tunnel...${NC}"
    
    echo -e "${YELLOW}----------------------------------------------------------------${NC}"
    echo -e "${YELLOW} 重要：接下来需要您手动进行浏览器授权。                         ${NC}"
    echo -e "${YELLOW}----------------------------------------------------------------${NC}"
    
    cloudflared tunnel login
    
    echo -e "请确认您已在浏览器中成功授权域名 (${GREEN}${DOMAIN}${NC})。"
    echo -e "授权成功后，请回到本终端..."
    pause_for_user

    echo -e "${BLUE}>>> 正在创建 Tunnel 并提取 UUID...${NC}"
    TUNNEL_INFO=$(cloudflared tunnel create ${TUNNEL_NAME})
    TUNNEL_UUID=$(echo "${TUNNEL_INFO}" | grep -oP '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}')
    
    if [ -z "$TUNNEL_UUID" ]; then
        echo -e "${RED}创建 Tunnel 失败或无法提取 Tunnel UUID。${NC}"
        echo -e "${RED}请检查您是否已成功授权。脚本将退出。${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Tunnel 创建成功, UUID: ${TUNNEL_UUID}${NC}"
    
    echo -e "${BLUE}>>> 正在生成 Cloudflared 配置文件...${NC}"
    mkdir -p ${CLOUDFLARED_CONFIG_DIR}
    CREDENTIALS_FILE="/root/.cloudflared/${TUNNEL_UUID}.json"

    cat << EOF > ${CLOUDFLARED_CONFIG_PATH}
tunnel: ${TUNNEL_UUID}
credentials-file: ${CREDENTIALS_FILE}
ingress:
  - hostname: ${DOMAIN}
    service: http://localhost:12861
  - service: http_status:404
EOF
    echo -e "${GREEN}Cloudflared 配置文件生成成功。${NC}"

    echo -e "${BLUE}>>> 正在将域名路由到 Tunnel...${NC}"
    cloudflared tunnel route dns ${TUNNEL_NAME} ${DOMAIN}
}

start_services() {
    echo -e "${BLUE}>>> 正在启动并设置所有服务开机自启...${NC}"
    systemctl restart xray
    systemctl enable xray
    
    cloudflared service install > /dev/null 2>&1
    systemctl start cloudflared
    systemctl enable cloudflared
    
    echo -e "${GREEN}所有服务已启动并设置为开机自启。${NC}"
}

display_config_info() {
    if [ ! -f "${XRAY_CONFIG_PATH}" ] || [ ! -f "${CLOUDFLARED_CONFIG_PATH}" ]; then
        echo -e "${RED}未找到完整的配置文件，无法显示信息。${NC}"
        return
    fi
    
    VLESS_UUID=$(grep -oP '"id": "\K[^"]+' ${XRAY_CONFIG_PATH})
    WS_PATH=$(grep -oP '"path": "\K[^"]+' ${XRAY_CONFIG_PATH})
    DOMAIN=$(grep -oP 'hostname: \K.*' ${CLOUDFLARED_CONFIG_PATH})

    clear
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}                 VWAW 安装成功! 配置信息如下                  ${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo -e " ${YELLOW}地址 (Address):         ${NC} ${DOMAIN} (或优选IP)"
    echo -e " ${YELLOW}端口 (Port):            ${NC} 443"
    echo -e " ${YELLOW}用户ID (UUID):          ${NC} ${VLESS_UUID}"
    echo -e " ${YELLOW}传输协议 (Network):     ${NC} ws"
    echo -e " ${YELLOW}路径 (Path):            ${NC} ${WS_PATH}"
    echo -e " ${YELLOW}传输安全 (TLS):         ${NC} tls"
    echo -e " "
    echo -e " ${YELLOW}--- 客户端兼容性关键参数 ---${NC}"
    echo -e " ${GREEN}servername / SNI:       ${NC} ${DOMAIN}"
    echo -e " ${GREEN}Host (in ws-headers):   ${NC} ${DOMAIN}"
    echo -e " "
    echo -e " ${BLUE}--- Clash/Stash YAML 格式示例 (请替换自选IP) ---${NC}"
    echo -e " - name: VWAW-Node"
    echo -e "   type: vless"
    echo -e "   server: 104.20.20.20 # <--- 替换为您自选的Cloudflare IP"
    echo -e "   port: 443"
    echo -e "   uuid: ${VLESS_UUID}"
    echo -e "   network: ws"
    echo -e "   tls: true"
    echo -e "   udp: false"
    echo -e "   servername: ${DOMAIN} # <--- 关键参数！确保Stash等客户端正常工作"
    echo -e "   ws-opts:"
    echo -e "     path: \"${WS_PATH}\""
    echo -e "     headers:"
    echo -e "       Host: ${DOMAIN}"
    echo -e "${GREEN}================================================================${NC}"
}

uninstall_vwaw() {
    echo -e "${RED}警告: 此操作将卸载 Xray, Cloudflared, WireProxy 并删除相关配置文件。${NC}"
    read -rp "您确定要继续吗? [y/N]: " confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        echo "卸载已取消。"
        exit 0
    fi
    
    echo -e "${BLUE}>>> 正在停止服务...${NC}"
    systemctl stop xray 2>/dev/null
    systemctl disable xray 2>/dev/null
    systemctl stop cloudflared 2>/dev/null
    systemctl disable cloudflared 2>/dev/null
    
    echo -e "${BLUE}>>> 正在卸载 Cloudflared...${NC}"
    if command -v cloudflared &> /dev/null; then
        cloudflared tunnel delete ${TUNNEL_NAME} 2>/dev/null
        cloudflared service uninstall > /dev/null 2>&1
        dpkg --purge cloudflared > /dev/null 2>&1
    fi
    
    echo -e "${BLUE}>>> 正在卸载 Xray...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge > /dev/null 2>&1
    
    echo -e "${BLUE}>>> 正在卸载 WireProxy (调用fscarmen脚本)...${NC}"
    if [ -f "menu.sh" ]; then
        echo "u" | ./menu.sh
    fi
    
    echo -e "${BLUE}>>> 正在删除配置文件和残留文件...${NC}"
    rm -rf ${CLOUDFLARED_CONFIG_DIR}
    rm -f menu.sh
    rm -f cloudflared.deb
    
    echo -e "${GREEN}VWAW 已成功卸载。${NC}"
}

# --- Main Menu Function ---

main_menu() {
    clear
    echo "-------------- VWAW 一键部署脚本 --------------"
    echo "          -- VLESS+WS+ArgoTunnel+WireProxy --"
    echo ""
    echo -e "${GREEN} 1. 安装 VWAW${NC}"
    echo -e "${RED} 2. 卸载 VWAW${NC}"
    echo "---------------------------------------------"
    echo -e "${BLUE} 3. 查看 配置信息${NC}"
    echo -e "${YELLOW} 4. 重启 所有服务${NC}"
    echo -e "${BLUE} 5. 更换 WARP 出口IP${NC}"
    echo -e "${YELLOW} 6. 打开 WARP 手动操作菜单${NC}"
    echo "---------------------------------------------"
    echo " 0. 退出脚本"
    echo ""
    read -rp "请输入数字 [0-6]: " choice

    case ${choice} in
        1)
            check_root
            check_os
            check_dependencies
            read -rp "请输入您准备用于隧道的域名 (例如 tunnel.yourdomain.com): " DOMAIN
            if [ -z "${DOMAIN}" ]; then
                echo -e "${RED}域名不能为空!${NC}"
                exit 1
            fi
            install_base_dependencies
            install_xray
            configure_xray
            install_wireproxy
            install_cloudflared
            configure_cloudflared
            start_services
            display_config_info
            ;;
        2)
            check_root
            uninstall_vwaw
            ;;
        3)
            display_config_info
            ;;
        4)
            check_root
            systemctl restart xray 2>/dev/null
            systemctl restart cloudflared 2>/dev/null
            echo "i" | ./menu.sh # A simple way to restart wireproxy
            echo -e "${GREEN}服务已尝试重启。${NC}"
            ;;
        5)
            check_root
            if [ -f "menu.sh" ]; then
                echo -e "${YELLOW}即将进入更换IP界面...${NC}"
                echo "i" | ./menu.sh
            else
                echo -e "${RED}未找到 'menu.sh' 脚本, 请先至少运行一次安装。${NC}"
            fi
            ;;
        6)
            check_root
            if [ -f "menu.sh" ]; then
                echo -e "${YELLOW}即将打开WARP手动操作菜单...${NC}"
                ./menu.sh
            else
                echo -e "${RED}未找到 'menu.sh' 脚本, 请先至少运行一次安装。${NC}"
            fi
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效输入，请输入正确的数字。${NC}"
            ;;
    esac
}

# --- Script Entrypoint ---
main_menu
