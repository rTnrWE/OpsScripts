#!/bin/bash
#
# Name: DNS-Pure.sh
# Description: Idempotent script to persistently set a clean DNS on Debian/Ubuntu.
# Author: rTnrWE (Enhanced by Gemini)
# Version: 1.3 - Enhanced feedback on initial check.
# curl -sSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/DNS-Pure/DNS-Pure.sh | sudo bash
# This script will:
# 1. First, check if the system's DNS is already the desired pure state.
# 2. If it is, exit immediately with a success message.
# 3. If not, provide specific reasons for the failure, then proceed with a
#    resilient process to fix the configuration.
# 4. Finally, verify the result.

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
    # 1. Check for root privileges first
    if [[ $EUID -ne 0 ]]; then
       echo -e "${RED}错误: 此脚本必须以 root 用户身份运行。请使用 'sudo'。${NC}"
       exit 1
    fi

    # 2. OPTIMIZED: Check the final state first with detailed feedback.
    echo "--> 正在进行首要检查：系统DNS是否已是纯净状态..."
    if command -v resolvectl &> /dev/null && resolvectl status &> /dev/null; then
        local current_dns
        current_dns=$(resolvectl status | awk '/^Global$/,/^$/ {if (/DNS Servers:/) {sub("DNS Servers: ", ""); print}}' | tr -s ' ')
        
        local current_domains
        current_domains=$(resolvectl status | awk '/^Global$/,/^$/ {if (/DNS Domain:/) {sub("DNS Domain: ", ""); print}}')

        # Check if both conditions are met
        if [[ "${current_dns}" == "${TARGET_DNS}" ]] && [[ -z "${current_domains}" ]]; then
            echo -e "\n${GREEN}✅ 状态完美！系统DNS已是 ${TARGET_DNS} 且无搜索域。无需任何操作。${NC}"
            exit 0
        else
            # NEW: Provide specific reasons for failure
            echo -e "${YELLOW}--> 检查未通过。原因如下：${NC}"
            if [[ "${current_dns}" != "${TARGET_DNS}" ]]; then
                echo -e "${YELLOW}    - 当前DNS为 [${current_dns:-未设置}]，与目标 [${TARGET_DNS}] 不符。${NC}"
            fi
            if [[ -n "${current_domains}" ]]; then
                echo -e "${YELLOW}    - 检测到不必要的搜索域：[${current_domains}]。${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}--> 检查失败：systemd-resolved 未安装或服务无响应。${NC}"
    fi
    
    echo -e "${YELLOW}--> 基于以上原因，将开始执行DNS净化流程...${NC}"

    # --- ACTION PHASE ---
    # This part only runs if the initial check fails.
    echo -e "\n--- 开始执行DNS净化流程 ---"

    # 3. Ensure systemd-resolved is installed
    if ! command -v resolvectl &> /dev/null; then
        echo "--> 正在安装 systemd-resolved..."
        if ! apt-get update -y > /dev/null; then
            echo -e "${YELLOW}--> 'apt-get update' 失败，尝试通过 ntpdate 同步时间...${NC}"
            (apt-get install -y ntpdate > /dev/null && ntpdate -s time.google.com && echo -e "${GREEN}--> ✅ 系统时间已同步。${NC}") || \
            (echo -e "${RED}--> 自动时间同步失败，请手动修复时间后重试。${NC}" && exit 1)
            apt-get update -y > /dev/null
        fi
        apt-get install -y systemd-resolved > /dev/null
        systemctl enable --now systemd-resolved
        echo -e "${GREEN}--> ✅ systemd-resolved 安装并启动成功。${NC}"
    fi

    # 4. Resiliency check and auto-repair
    echo "--> 正在确保 systemd-resolved 服务响应正常..."
    if ! resolvectl status &> /dev/null; then
        echo -e "${YELLOW}--> 服务未响应。正在尝试强制重新初始化...${NC}"
        systemctl stop systemd-resolved &> /dev/null || true
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        systemctl start systemd-resolved
        sleep 2
        if ! resolvectl status &> /dev/null; then
            echo -e "${RED}错误：强制初始化后服务仍然无响应。请手动排查。${NC}"
            exit 1
        fi
        echo -e "${GREEN}--> ✅ 服务已成功初始化并响应。${NC}"
    else
         echo -e "${GREEN}--> ✅ 服务响应正常。${NC}"
    fi

    # 5. Apply new configuration
    echo "--> 正在应用纯净DNS配置..."
    echo -e "[Resolve]\nDNS=${TARGET_DNS}\nDomains=" > /etc/systemd/resolved.conf
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
    sleep 1
    echo -e "${GREEN}--> ✅ DNS 配置修改并重启服务成功。${NC}"

    # 6. Final verification
    echo -e "\n${GREEN}✅ 全部操作完成！以下是最终的 DNS 状态：${NC}"
    echo "----------------------------------------------------"
    resolvectl status
}

# Run the main function
main
