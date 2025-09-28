#!/bin/bash
#
# Name: DNS-Pure.sh
# Description: Persistently set a clean DNS on Debian/Ubuntu using systemd-resolved.
# Author: rTnrWE (Enhanced by Gemini)
# Version: 1.1 - Added resiliency for non-responsive service.
#
# This script will:
# 1. Check for root privileges.
# 2. Ensure systemd-resolved is installed.
# 3. Check if the systemd-resolved service is responsive and auto-repair if not.
# 4. Check if the DNS is already correctly configured.
# 5. If not, apply the new DNS settings (8.8.8.8, 1.1.1.1) and disable search domains.
# 6. Verify the final configuration.

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
readonly TARGET_DNS="8.8.8.8 1.1.1.1"
# ---------------------

# --- Color Codes for Output ---
readonly GREEN="\033[0;32m"
readonly YELLOW="\033[1;33m"
readonly RED="\033[0;31m"
readonly NC="\033[0m" # No Color

# --- Main Logic ---
main() {
    # 1. Check for root privileges
    if [[ $EUID -ne 0 ]]; then
       echo -e "${RED}错误: 此脚本必须以 root 用户身份运行。请使用 'sudo'。${NC}"
       exit 1
    fi

    # 2. Ensure systemd-resolved is installed
    if ! command -v resolvectl &> /dev/null; then
        echo -e "${YELLOW}--> 检测到 systemd-resolved 未安装，正在自动安装...${NC}"
        # Correct time issues before proceeding with apt
        if ! apt-get update -y > /dev/null; then
            echo -e "${YELLOW}--> 'apt-get update' 失败，可能是系统时间不正确。正在尝试修复...${NC}"
            apt-get install -y ntpdate > /dev/null && ntpdate time.google.com && echo -e "${GREEN}--> ✅ 系统时间已同步。${NC}" || echo -e "${RED}--> 自动时间同步失败，请手动修复时间后重试。${NC}"
            apt-get update -y > /dev/null
        fi
        apt-get install -y systemd-resolved > /dev/null
        systemctl enable --now systemd-resolved
        echo -e "${GREEN}--> ✅ systemd-resolved 安装并启动成功。${NC}"
    else
        echo -e "${GREEN}--> systemd-resolved 已安装。${NC}"
    fi

    # 3. NEW: Resiliency check and auto-repair for the service
    echo "--> 正在检查 systemd-resolved 服务响应..."
    if ! resolvectl status &> /dev/null; then
        echo -e "${YELLOW}--> 服务未响应。正在尝试强制重新初始化...${NC}"
        
        # The re-initialization sequence
        systemctl stop systemd-resolved &> /dev/null || true # Ignore error if already stopped
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        systemctl start systemd-resolved
        sleep 2 # Give it a moment to initialize
        
        # Final check after the repair attempt
        if ! resolvectl status &> /dev/null; then
            echo -e "${RED}错误：强制初始化后，systemd-resolved 服务仍然无法启动或响应。${NC}"
            echo -e "${RED}请手动运行 'systemctl status systemd-resolved' 和 'journalctl -u systemd-resolved' 来诊断问题。${NC}"
            exit 1
        else
            echo -e "${GREEN}--> ✅ 服务已成功初始化并响应。${NC}"
        fi
    else
         echo -e "${GREEN}--> ✅ systemd-resolved 服务响应正常。${NC}"
    fi

    # 4. Check current DNS and Domain configuration
    local current_dns
    current_dns=$(resolvectl status | awk '/^Global$/,/^$/ {if (/DNS Servers:/) {sub("DNS Servers: ", ""); print}}' | tr -s ' ')
    
    local current_domains
    current_domains=$(resolvectl status | awk '/^Global$/,/^$/ {if (/DNS Domain:/) {sub("DNS Domain: ", ""); print}}')

    echo "--> 当前全局DNS: [${current_dns:-未设置}]"
    echo "--> 当前搜索域: [${current_domains:-未设置}]"

    # Compare current configuration with the target
    if [[ "${current_dns}" == "${TARGET_DNS}" ]] && [[ -z "${current_domains}" ]]; then
        echo -e "\n${GREEN}✅ DNS 已是最新配置 ( ${TARGET_DNS} )，无需修改。脚本退出。${NC}"
        exit 0
    fi

    # 5. Apply new configuration
    echo -e "\n${YELLOW}--> DNS 配置不匹配，开始执行修改...${NC}"
    echo -e "[Resolve]\nDNS=${TARGET_DNS}\nDomains=" > /etc/systemd/resolved.conf
    # The symlink is already set during the resiliency check, but we do it again for consistency
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
    sleep 1
    echo -e "${GREEN}--> ✅ DNS 配置修改并重启服务成功。${NC}"

    # 6. Final verification
    echo -e "\n${GREEN}✅ 全部操作完成！以下是更新后的 DNS 状态：${NC}"
    echo "----------------------------------------------------"
    resolvectl status
}

# Run the main function
main
