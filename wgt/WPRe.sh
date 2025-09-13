#!/bin/bash

#====================================================================================
# WPRe.sh - WireProxy IP Refresher
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
# The configuration file for WireProxy.
readonly WARP_CONFIG_PATH="/etc/wireguard/proxy.conf"
# The domain WireProxy uses to find Cloudflare endpoints.
readonly WARP_ENDPOINT_DOMAIN="engage.cloudflareclient.com"
# The absolute path to the fscarmen script.
readonly FSCARMEN_SCRIPT_PATH="/etc/wireguard/menu.sh"

# --- Colors for Output ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# --- Utility Functions ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误: 此脚本必须以root用户权限运行。${NC}"
        exit 1
    fi
}

check_dependencies() {
    local missing_deps=()
    for cmd in curl wget sed; do
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
    # Robustly extract the port number
    SOCKS_PORT=$(grep "BindAddress" "${WARP_CONFIG_PATH}" | awk -F':' '{print $2}' | tr -d '[:space:]')
    if ! [[ "${SOCKS_PORT}" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 无法从配置文件中自动检测SOCKS5端口。${NC}"
        exit 1
    fi
    echo "${SOCKS_PORT}"
}

get_current_warp_ip() {
    local port=$1
    echo -e "${BLUE}>>> 正在检测当前的WARP出口IP...${NC}"
    CURRENT_IP=$(curl -s --max-time 10 --proxy "socks5h://127.0.0.1:${port}" ip.sb)
    if [ -z "${CURRENT_IP}" ]; then
        echo -e "${RED}无法获取当前的出口IP。请检查WireProxy服务是否正在运行。${NC}"
        echo -e "${YELLOW}您可以尝试手动运行 '${FSCARMEN_SCRIPT_PATH}' 并选择 'y' 选项来重启服务。${NC}"
        exit 1
    fi
    echo -e "当前的出口IP是: ${GREEN}${CURRENT_IP}${NC}"
}

flip_the_ip() {
    local port=$1
    local current_ip=$2
    echo -e "\n${YELLOW}--- 开始执行强制IP刷新 ---${NC}"

    # 1. Hijack domain resolution
    echo -e "${BLUE}[1/5] 正在通过 /etc/hosts 临时劫持域名...${NC}"
    sed -i.bak "/${WARP_ENDPOINT_DOMAIN}/d" /etc/hosts
    echo "127.0.0.1 ${WARP_ENDPOINT_DOMAIN}" >> /etc/hosts

    # 2. Restart service (expected to fail)
    echo -e "${BLUE}[2/5] 第一次重启服务 (以重置状态)...${NC}"
    echo "y" | ${FSCARMEN_SCRIPT_PATH} > /dev/null 2>&1
    sleep 5

    # 3. Restore domain resolution
    echo -e "${BLUE}[3/5] 正在恢复正常的域名解析...${NC}"
    sed -i "/${WARP_ENDPOINT_DOMAIN}/d" /etc/hosts

    # --- Verification Step ---
    if grep -q "${WARP_ENDPOINT_DOMAIN}" /etc/hosts; then
        echo -e "${RED}严重错误: 无法从 /etc/hosts 文件中移除劫持条目！${NC}"
        echo -e "${YELLOW}为避免网络问题，脚本将终止。请手动编辑 /etc/hosts 并删除相关行。${NC}"
        mv /etc/hosts.bak /etc/hosts # Restore from backup
        exit 1
    fi
    rm -f /etc/hosts.bak

    # 4. Restart service again (to get new IP)
    echo -e "${BLUE}[4/5] 第二次重启服务 (获取新IP)...${NC}"
    echo "y" | ${FSCARMEN_SCRIPT_PATH} > /dev/null 2>&1

    # 5. Final validation
    echo -e "${BLUE}[5/5] 等待服务稳定并检查新IP...${NC}"
    sleep 8
    NEW_IP=$(curl -s --max-time 15 --proxy "socks5h://127.0.0.1:${port}" ip.sb)

    echo -e "\n${GREEN}--- IP刷新操作完成 ---${NC}"
    if [ -n "${NEW_IP}" ]; then
        if [ "${NEW_IP}" != "${current_ip}" ]; then
            echo -e "恭喜！您的WARP出口IP已成功更换！"
            echo -e "旧IP: ${RED}${current_ip}${NC}"
            echo -e "新IP: ${GREEN}${NEW_IP}${NC}"
        else
            echo -e "${YELLOW}操作完成，但IP没有变化。可能是Cloudflare分配了相同的IP。${NC}"
            echo -e "您可以稍后重试。当前IP: ${GREEN}${NEW_IP}${NC}"
        fi
    else
        echo -e "${RED}操作失败！无法获取新的出口IP。${NC}"
        echo -e "${YELLOW}请尝试手动运行 '${FSCARMEN_SCRIPT_PATH}' 并选择 'y' 来重启服务进行排错。${NC}"
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

    local current_ip
    current_ip=$(get_current_warp_ip "${socks_port}")
    
    echo ""
    read -rp "您想现在强制刷新这个IP吗? [y/N]: " confirm
    if [[ "${confirm}" =~ ^[yY]$ ]]; then
        flip_the_ip "${socks_port}" "${current_ip}"
    else
        echo "操作已取消。"
    fi
    
    echo -e "\n脚本执行完毕。"
}

# Run the main function
main
