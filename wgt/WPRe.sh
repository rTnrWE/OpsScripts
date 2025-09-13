#!/bin/bash

#====================================================================================
# WPRe.sh - WireProxy IP Refresher (Dual Stack IPv4/IPv6)
#
#   Description: Reliably refreshes the WireProxy SOCKS5 exit IP for installations
#                managed by the fscarmen/warp script.
#   Usage:
#   wget --no-check-certificate "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/wgt/WPRe.sh" -O WPRe.sh && chmod +x WPRe.sh && ./WPRe.sh
#
#====================================================================================

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Script Configuration ---
readonly WARP_CONFIG_PATH="/etc/wireguard/proxy.conf"
readonly WARP_ENDPOINT_DOMAIN="engage.cloudflareclient.com"
readonly FSCARMEN_SCRIPT_PATH="/etc/wireguard/menu.sh"
readonly WIREPROXY_SERVICE_NAME="wireproxy.service"

# --- Colors for Output ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# --- Global Variables for IP storage ---
CURRENT_IP_V4=""
CURRENT_IP_V6=""

# --- Utility Functions ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误: 此脚本必须以root用户权限运行。${NC}"
        exit 1
    fi
}

check_dependencies() {
    local missing_deps=()
    for cmd in curl wget sed awk systemctl; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${RED}错误: 缺少核心依赖: ${missing_deps[*]}${NC}"
        echo -e "${YELLOW}请运行 'apt update && apt install -y ${missing_deps[*]}' 来安装它们。${NC}"
        exit 1
    fi

    if [ ! -f "${FSCARMEN_SCRIPT_PATH}" ]; then
        echo -e "${RED}错误: 未找到 fscarmen 脚本: ${FSCARMEN_SCRIPT_PATH}${NC}"
        echo -e "${YELLOW}请确保您已经通过 fscarmen/warp 脚本成功安装了 WireProxy。${NC}"
        exit 1
    fi
}

# --- Core Functions ---

get_socks_port() {
    if [ ! -f "${WARP_CONFIG_PATH}" ]; then
        echo -e "${RED}错误: 找不到WARP配置文件: ${WARP_CONFIG_PATH}${NC}"
        exit 1
    fi
    SOCKS_PORT=$(awk '/^\[Socks5\]/{f=1} f && /BindAddress/{split($3, a, ":"); print a[2]; exit}' "${WARP_CONFIG_PATH}")

    if ! [[ "${SOCKS_PORT}" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 无法从配置文件的 [Socks5] 部分自动检测SOCKS5端口。${NC}"
        exit 1
    fi
    echo "${SOCKS_PORT}"
}

get_current_warp_ip() {
    local port=$1
    echo -e "${BLUE}>>> 正在检测当前的WARP双栈出口IP...${NC}"
    
    CURRENT_IP_V4=$(curl -s -4 --max-time 10 --proxy "socks5h://127.0.0.1:${port}" ip.sb || echo "不可用")
    CURRENT_IP_V6=$(curl -s -6 --max-time 10 --proxy "socks5h://127.0.0.1:${port}" ip.sb || echo "不可用")

    if [[ "${CURRENT_IP_V4}" == "不可用" && "${CURRENT_IP_V6}" == "不可用" ]]; then
        echo -e "${RED}无法获取任何出口IP。请检查WireProxy服务是否正在运行。${NC}"
        echo -e "${YELLOW}您可以尝试手动运行 'systemctl restart ${WIRELOCK_SERVICE_NAME}'。${NC}"
        exit 1
    fi
    echo -e "当前的IPv4出口是: ${GREEN}${CURRENT_IP_V4}${NC}"
    echo -e "当前的IPv6出口是: ${GREEN}${CURRENT_IP_V6}${NC}"
}

flip_the_ip() {
    local port=$1
    echo -e "\n${YELLOW}--- 开始执行强制IP刷新 ---${NC}"

    # 1. Hijack domain resolution
    echo -e "${BLUE}[1/5] 正在通过 /etc/hosts 临时劫持域名...${NC}"
    sed -i.bak "/${WARP_ENDPOINT_DOMAIN}/d" /etc/hosts
    echo "127.0.0.1 ${WARP_ENDPOINT_DOMAIN}" >> /etc/hosts

    # 2. Restart service (expected to fail) using systemctl
    echo -e "${BLUE}[2/5] 第一次重启服务 (以重置状态)...${NC}"
    systemctl restart "${WIREPROXY_SERVICE_NAME}"
    sleep 5

    # 3. Restore domain resolution
    echo -e "${BLUE}[3/5] 正在恢复正常的域名解析...${NC}"
    sed -i "/${WARP_ENDPOINT_DOMAIN}/d" /etc/hosts
    if grep -q "${WARP_ENDPOINT_DOMAIN}" /etc/hosts; then
        echo -e "${RED}严重错误: 无法从 /etc/hosts 文件中移除劫持条目！${NC}"
        mv /etc/hosts.bak /etc/hosts
        exit 1
    fi
    rm -f /etc/hosts.bak

    # 4. Restart service again (to get new IP) using systemctl
    echo -e "${BLUE}[4/5] 第二次重启服务 (获取新IP)...${NC}"
    systemctl restart "${WIREPROXY_SERVICE_NAME}"

    # 5. Final validation
    echo -e "${BLUE}[5/5] 等待服务稳定并检查新双栈IP...${NC}"
    sleep 8
    NEW_IP_V4=$(curl -s -4 --max-time 15 --proxy "socks5h://127.0.0.1:${port}" ip.sb || echo "不可用")
    NEW_IP_V6=$(curl -s -6 --max-time 15 --proxy "socks5h://127.0.0.1:${port}" ip.sb || echo "不可用")

    echo -e "\n${GREEN}--- IP刷新操作完成 ---${NC}"
    if [[ "${NEW_IP_V4}" == "不可用" && "${NEW_IP_V6}" == "不可用" ]]; then
        echo -e "${RED}操作失败！无法获取任何新的出口IP。${NC}"
    else
        if [[ "${NEW_IP_V4}" != "${CURRENT_IP_V4}" || "${NEW_IP_V6}" != "${CURRENT_IP_V6}" ]]; then
            echo -e "恭喜！您的WARP出口IP已成功更换！"
            echo -e "旧IPv4: ${RED}${CURRENT_IP_V4}${NC} -> 新IPv4: ${GREEN}${NEW_IP_V4}${NC}"
            echo -e "旧IPv6: ${RED}${CURRENT_IP_V6}${NC} -> 新IPv6: ${GREEN}${NEW_IP_V6}${NC}"
        else
            echo -e "${YELLOW}操作完成，但IP没有变化。可能是Cloudflare分配了相同的IP。${NC}"
            echo -e "当前IPv4: ${GREEN}${NEW_IP_V4}${NC}"
            echo -e "当前IPv6: ${GREEN}${NEW_IP_V6}${NC}"
        fi
    fi
}

# --- Script Entrypoint ---
main() {
    clear
    echo "-------------- WPRe.sh (WARP IP Refresher) --------------"
    echo "        - 专为 fscarmen/warp 的WireProxy设计 -"
    echo ""

    check_root
    check_dependencies

    local socks_port
    socks_port=$(get_socks_port)
    echo -e "${BLUE}成功检测到SOCKS5端口: ${GREEN}${socks_port}${NC}\n"

    get_current_warp_ip "${socks_port}"
    
    echo ""
    read -rp "您想现在强制刷新这个IP吗? [y/N]: " confirm
    if [[ "${confirm}" =~ ^[yY]$ ]]; then
        flip_the_ip "${socks_port}"
    else
        echo "操作已取消。"
    fi
    
    echo -e "\n脚本执行完毕。"
}

# Run the main function
main
