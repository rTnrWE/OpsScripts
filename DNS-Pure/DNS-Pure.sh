#!/bin/bash
#
# Description: Persistently set DNS on Debian 12 using systemd-resolved.
# Author: Your Name
# Version: 1.0
#
# This script will:
# 1. Check for root privileges.
# 2. Ensure systemd-resolved is installed.
# 3. Check if the DNS is already correctly configured.
# 4. If not, apply the new DNS settings (8.8.8.8, 1.1.1.1) and disable search domains.
# 5. Verify the final configuration.

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
# Set your desired target DNS servers here.
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
        # Suppress unnecessary output with > /dev/null
        apt-get update -y > /dev/null
        apt-get install -y systemd-resolved > /dev/null
        systemctl enable --now systemd-resolved
        echo -e "${GREEN}--> ✅ systemd-resolved 安装并启动成功。${NC}"
    else
        echo -e "${GREEN}--> systemd-resolved 已安装，继续执行检查。${NC}"
    fi

    # 3. Check current DNS and Domain configuration
    # Use awk for more robust parsing of resolvectl's output
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

    # 4. Apply new configuration
    echo -e "\n${YELLOW}--> DNS 配置不匹配，开始执行修改...${NC}"
    # Create/overwrite the configuration file
    echo -e "[Resolve]\nDNS=${TARGET_DNS}\nDomains=" > /etc/systemd/resolved.conf
    # Ensure the resolv.conf symlink is correct
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    # Restart the service to apply changes
    systemctl restart systemd-resolved
    # Brief pause to allow the service to settle
    sleep 1
    echo -e "${GREEN}--> ✅ DNS 配置修改并重启服务成功。${NC}"

    # 5. Final verification
    echo -e "\n${GREEN}✅ 全部操作完成！以下是更新后的 DNS 状态：${NC}"
    echo "----------------------------------------------------"
    resolvectl status
}

# Run the main function
main