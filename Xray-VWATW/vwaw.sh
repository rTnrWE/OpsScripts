#!/bin/bash

#====================================================================================
# vwaw.sh - VLESS+WS+ArgoTunnel+WireProxy Auto-Installer
#
#   Author: Gemini & Collaborator
#   Version: 1.0.0
#   Description: Automates the setup of a secure and robust proxy solution.
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

install_dependencies() {
    echo -e "${BLUE}>>> 正在更新软件包列表并安装依赖...${NC}"
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
    echo -e "${BLUE}>>> 即将调用 fscarmen/warp 脚本安装 WireProxy (SOCKS5)...${NC}"
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh > /dev/null 2>&1
    
    # 尝试以非交互方式运行选项 'w' (13)
    # 注意: 这取决于 fscarmen 脚本是否支持这种调用方式。
    # 如果不支持，用户可能需要手动选择。
    echo "w" | bash menu.sh
    
    # 检查SOCKS5代理端口是否已监听
    if ! lsof -i:40000 > /dev/null; then
        echo -e "${YELLOW}WireProxy SOCKS5 代理似乎未启动。请尝试手动运行 'bash menu.sh' 并选择选项 13。${NC}"
        echo -e "${YELLOW}脚本将继续，但您需要手动确保 SOCKS5 代理正常运行。${NC}"
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
    
    # 获取授权链接
    LOGIN_URL=$(cloudflared tunnel login | grep -o 'https://dash.cloudflare.com/[^ ]*')

    if [ -z "$LOGIN_URL" ]; then
        echo -e "${RED}无法获取Cloudflare授权链接，请检查网络或Cloudflared安装。${NC}"
        exit 1
    fi
    
    echo -e "请复制以下链接，并在您 ${GREEN}本地电脑的浏览器${NC} 中打开它："
    echo -e "${BLUE}${LOGIN_URL}${NC}"
    echo -e "请选择您要使用的域名 (${GREEN}${DOMAIN}${NC}) 进行授权。"
    echo -e "授权成功后，请回到本终端..."
    pause_for_user

    # 创建隧道并提取UUID
    echo -e "${BLUE}>>> 正在创建 Tunnel 并提取 UUID...${NC}"
    TUNNEL_INFO=$(cloudflared tunnel create ${TUNNEL_NAME})
    TUNNEL_UUID=$(echo "${TUNNEL_INFO}" | grep -oP '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}')
    
    if [ -z "$TUNNEL_UUID" ]; then
        echo -e "${RED}创建 Tunnel 失败或无法提取 Tunnel UUID。${NC}"
        echo -e "${RED}请检查您是否已成功授权。${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Tunnel 创建成功, UUID: ${TUNNEL_UUID}${NC}"
    
    # 生成配置文件
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

    # 路由域名
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
    # 重新从文件中读取，确保信息最新
    VLESS_UUID=$(grep -oP '"id": "\K[^"]+' ${XRAY_CONFIG_PATH})
    WS_PATH=$(grep -oP '"path": "\K[^"]+' ${XRAY_CONFIG_PATH})

    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}                 VWAW 安装成功! 配置信息如下                  ${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo -e " ${YELLOW}地址 (Address):         ${NC} ${DOMAIN}"
    echo -e " ${YELLOW}端口 (Port):            ${NC} 443"
    echo -e " ${YELLOW}用户ID (UUID):          ${NC} ${VLESS_UUID}"
    echo -e " ${YELLOW}传输协议 (Network):     ${NC} ws"
    echo -e " ${YELLOW}路径 (Path):            ${NC} ${WS_PATH}"
    echo -e " ${YELLOW}传输安全 (TLS):         ${NC} tls"
    echo -e " ${YELLOW}主机/SNI (Host):        ${NC} ${DOMAIN}"
    echo -e " "
    echo -e " ${BLUE}--- 客户端自选IP优化 ---${NC}"
    echo -e " 1. 使用工具 (如 aist.site) 查找对您本地网络最优的Cloudflare IP。"
    echo -e " 2. 在客户端配置中，将 ${YELLOW}地址 (Address)${NC} 修改为您找到的IP。"
    echo -e " 3. 确保 ${YELLOW}主机/SNI (Host)${NC} 字段 ${RED}仍然是${NC} ${YELLOW}${DOMAIN}${NC}。"
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
    systemctl stop xray
    systemctl disable xray
    systemctl stop cloudflared
    systemctl disable cloudflared
    
    echo -e "${BLUE}>>> 正在卸载 Cloudflared...${NC}"
    if command -v cloudflared &> /dev/null; then
        TUNNEL_UUID=$(grep -oP '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' ${CLOUDFLARED_CONFIG_PATH} 2>/dev/null)
        if [ -n "$TUNNEL_UUID" ]; then
             cloudflared tunnel delete ${TUNNEL_NAME}
        fi
        cloudflared service uninstall > /dev/null 2>&1
        dpkg --purge cloudflared > /dev/null 2>&1
    fi
    
    echo -e "${BLUE}>>> 正在卸载 Xray...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge > /dev/null 2>&1
    
    echo -e "${BLUE}>>> 正在卸载 WireProxy (调用fscarmen脚本)...${NC}"
    if [ -f "menu.sh" ]; then
        echo "u" | bash menu.sh
    fi
    
    echo -e "${BLUE}>>> 正在删除配置文件和残留文件...${NC}"
    rm -rf ${CLOUDFLARED_CONFIG_DIR}
    rm -f menu.sh
    rm -f cloudflared.deb
    
    echo -e "${GREEN}VWAW 已成功卸载。${NC}"
}

# --- Main Function ---

main_menu() {
    clear
    echo "-------------- VWAW 一键部署脚本 --------------"
    echo "          -- VLESS+WS+ArgoTunnel+WireProxy --"
    echo ""
    echo -e "${GREEN} 1. 安装 VWAW (首次使用请选此项)${NC}"
    echo -e "${RED} 2. 卸载 VWAW (将移除所有相关组件)${NC}"
    echo "---------------------------------------------"
    echo -e "${BLUE} 3. 查看 VWAW 配置信息${NC}"
    echo -e "${YELLOW} 4. 重启 VWAW 所有服务${NC}"
    echo "---------------------------------------------"
    echo " 0. 退出脚本"
    echo ""
    read -rp "请输入数字 [0-4]: " choice

    case ${choice} in
        1)
            check_root
            check_os
            read -rp "请输入您准备用于隧道的域名 (例如 tunnel.yourdomain.com): " DOMAIN
            if [ -z "${DOMAIN}" ]; then
                echo -e "${RED}域名不能为空!${NC}"
                exit 1
            fi
            install_dependencies
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
            if [ -f "${XRAY_CONFIG_PATH}" ]; then
                DOMAIN=$(grep -oP 'hostname: \K.*' ${CLOUDFLARED_CONFIG_PATH} 2>/dev/null)
                display_config_info
            else
                echo -e "${RED}未找到配置文件，请先安装。${NC}"
            fi
            ;;
        4)
            check_root
            systemctl restart xray
            systemctl restart cloudflared
            echo -e "${GREEN}服务已重启。${NC}"
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