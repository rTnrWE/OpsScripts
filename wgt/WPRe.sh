#!/bin/bash

#====================================================================================
# WPRe.sh - WireProxy IP Refresher
#
#   Description: Reliably refreshes the WireProxy SOCKS5 exit IP for installations
#                managed by the fscarmen/warp script.
#   Usage:
#   wget -N --no-check-certificate "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/wgt/WPRe.sh" && chmod +x WPRe.sh && ./WPRe.sh
#
#====================================================================================

# --- Script Configuration ---
# The configuration file for WireProxy.
readonly WARP_CONFIG_PATH="/etc/wireguard/proxy.conf"
# The domain WireProxy uses to find Cloudflare endpoints.
readonly WARP_ENDPOINT_DOMAIN="engage.cloudflareclient.com"
# The path to the fscarmen script.
readonly FSCARMEN_SCRIPT_PATH="./menu.sh"

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
        echo -e "${RED}错误: 未在当前目录找到 'menu.sh' 脚本。${NC}"
        echo -e "${YELLOW}正在尝试自动下载...${NC}"
        wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh > /dev/null 2>&1
        if [ $? -ne 0 ] || [ ! -f "${FSCARMEN_SCRIPT_PATH}" ]; then
            echo -e "${RED}自动下载 'menu.sh' 失败。请手动下载后重试。${NC}"
            exit 1
        fi
        chmod +x ${FSCARMEN_SCRIPT_PATH}
        echo -e "${GREEN}'menu.sh' 已成功下载。${NC}"
    fi
}

# --- Core Functions ---

get_socks_port() {
    if [ ! -f "${WARP_CONFIG_PATH}" ]; then
        echo -e "${RED}错误: 找不到WARP配置文件: ${WARP_CONFIG_PATH}${NC}"
        return 1
    fi
    # Using a more compatible way to extract the port number
    SOCKS_PORT=$(grep "BindAddress" "${WARP_CONFIG_PATH}" | awk -F':' '{print $2}' | tr -d ' ')
    if ! [[ "${SOCKS_PORT}" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 无法从配置文件中自动检测SOCKS5端口。${NC}"
        return 1
    fi
    echo "${SOCKS_PORT}"
}

get_current_warp_ip() {
    local port=$1
    echo -e "${BLUE}>>> 正在检测当前的WARP出口IP...${NC}"
    CURRENT_IP=$(curl -s --max-time 10 --proxy "socks5h://127.0.0.1:${port}" ip.sb)
    if [ -z "${CURRENT_IP}" ]; then
        echo -e "${RED}无法获取当前的出口IP。请检查WireProxy服务是否正在运行。${NC}"
        echo -e "${YELLOW}您可以尝试手动运行 './menu.sh' 并选择 'y' 选项来重启服务。${NC}"
        return 1
    fi
    echo -e "当前的出口IP是: ${GREEN}${CURRENT_IP}${NC}"
}

flip_the_ip() {
    local port=$1
    echo -e "\n${YELLOW}--- 开始执行强制IP刷新 ---${NC}"

    # 1. 劫持域名解析
    echo -e "${BLUE}[1/5] 正在通过 /etc/hosts 临时劫持域名...${NC}"
    # Clean up any previous stale entries first
    sed -i "/${WARP_ENDPOINT_DOMAIN}/d" /etc/hosts
    echo "127.0.0.1 ${WARP_ENDPOINT_DOMAIN}" >> /etc/hosts

    # 2. 尝试重启wireproxy，此时它会因为域名被劫持而连接失败
    echo -e "${BLUE}[2/5] 第一次重启服务 (预期会失败，以重置状态)...${NC}"
    echo "y" | ${FSCARMEN_SCRIPT_PATH} > /dev/null 2>&1
    sleep 5

    # 3. 恢复域名解析
    echo -e "${BLUE}[3/5] 正在恢复正常的域名解析...${NC}"
    sed -i "/${WARP_ENDPOINT_DOMAIN}/d" /etc/hosts

    # --- Verification Step ---
    if grep -q "${WARP_ENDPOINT_DOMAIN}" /etc/hosts; then
        echo -e "${RED}严重错误: 无法从 /etc/hosts 文件中移除劫持条目！${NC}"
        echo -e "${YELLOW}为避免网络问题，脚本将终止。请手动编辑 /etc/hosts 文件并删除包含 '${WARP_ENDPOINT_DOMAIN}' 的行。${NC}"
        exit 1
    fi

    # 4. 再次重启wireproxy，现在它可以正常解析并获取新的Endpoint了
    echo -e "${BLUE}[4/5] 第二次重启服务 (获取新IP)...${NC}"
    echo "y" | ${FSCARMEN_SCRIPT_PATH} > /dev/null 2>&1

    # 5. 最终验证
    echo -e "${BLUE}[5/5] 等待服务稳定并检查新IP...${NC}"
    sleep 8 # Wait a bit longer for the service to fully stabilize
    NEW_IP=$(curl -s --max-time 15 --proxy "socks5h://127.0.0.1:${port}" ip.sb)

    echo -e "\n${GREEN}--- IP刷新操作完成 ---${NC}"
    if [ -n "${NEW_IP}" ]; then
        if [ "${NEW_IP}" != "${CURRENT_IP}" ]; then
            echo -e "恭喜！您的WARP出口IP已成功更换！"
            echo -e "旧IP: ${RED}${CURRENT_IP}${NC}"
            echo -e "新IP: ${GREEN}${NEW_IP}${NC}"
        else
            echo -e "${YELLOW}操作完成，但IP没有变化。可能是Cloudflare分配了相同的IP。${NC}"
            echo -e "您可以稍后重试。当前IP: ${GREEN}${NEW_IP}${NC}"
        fi
    else
        echo -e "${RED}操作失败！无法获取新的出口IP。${NC}"
        echo -e "${YELLOW}请尝试手动运行 './menu.sh' 并选择 'y' 来重启服务进行排错。${NC}"
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

    SOCKS_PORT=$(get_socks_port)
    if [ $? -ne 0 ]; then
        exit 1
    fi
    echo -e "${BLUE}成功检测到SOCKS5端口: ${GREEN}${SOCKS_PORT}${NC}\n"

    get_current_warp_ip "${SOCKS_PORT}"
    if [ $? -ne 0 ]; then
        exit 1
    fi
    
    echo ""
    read -rp "您想现在强制刷新这个IP吗? [y/N]: " confirm
    if [[ "${confirm}" =~ ^[yY]$ ]]; then
        flip_the_ip "${SOCKS_PORT}"
    else
        echo "操作已取消。"
    fi
    
    echo -e "\n脚本执行完毕。"
}

main
