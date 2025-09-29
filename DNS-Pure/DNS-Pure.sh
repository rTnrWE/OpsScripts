#!/usr/bin/env bash
#
# Name:         DNS-Pure.sh
# Description:  An intelligent script that purifies and hardens the system's DNS
#               by optimally configuring systemd-resolved. It prioritizes
#               DNS over TLS (DoT) and other security best practices for servers.
# Author:       rTnrWE
# Version:      2.2
#
# Usage:
# curl -sSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/DNS-Pure/DNS-Pure.sh | sudo bash
#

# --- Script Configuration and Safety ---
set -euo pipefail

# --- Global Constants: The Ultimate Secure DNS Configuration ---
readonly TARGET_DNS="8.8.8.8#dns.google 1.1.1.1#cloudflare-dns.com"
readonly SECURE_RESOLVED_CONFIG="[Resolve]
DNS=${TARGET_DNS}
LLMNR=no
MulticastDNS=no
DNSSEC=allow-downgrade
DNSOverTLS=yes
"
readonly GREEN="\033[0;32m"
readonly YELLOW="\033[1;33m"
readonly RED="\033[0;31m"
readonly NC="\033[0m" # No Color

# --- Helper Functions ---
# This function contains the full installation and hardening logic.
purify_and_harden_dns() {
    echo -e "\n--- 开始执行DNS净化与安全加固流程 ---"

    # 1. Ensure systemd-resolved is installed.
    if ! command -v resolvectl &> /dev/null; then
        echo "--> 正在安装 systemd-resolved..."
        if ! apt-get update -y > /dev/null; then
            echo -e "${YELLOW}--> 'apt-get update' 失败，尝试通过 ntpdate 同步时间...${NC}"
            if apt-get install -y ntpdate > /dev/null && ntpdate -s time.google.com; then
                 echo -e "${GREEN}--> ✅ 系统时间已同步。${NC}"
            else
                 echo -e "${RED}--> 自动时间同步失败，请手动修复时间后重试。${NC}" >&2
                 exit 1
            fi
            apt-get update -y > /dev/null
        fi
        apt-get install -y systemd-resolved > /dev/null
        systemctl enable --now systemd-resolved
        echo -e "${GREEN}--> ✅ systemd-resolved 安装并启动成功。${NC}"
    fi

    # 2. Resiliency Check: Ensure the service is responsive.
    echo "--> 正在确保 systemd-resolved 服务响应正常..."
    if ! resolvectl status &> /dev/null; then
        echo -e "${YELLOW}--> 服务未响应。正在尝试强制重新初始化...${NC}"
        systemctl stop systemd-resolved &> /dev/null || true
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        systemctl start systemd-resolved
        sleep 2
        
        if ! resolvectl status &> /dev/null; then
            echo -e "${RED}错误：强制初始化后服务仍然无响应。请手动排查。${NC}" >&2
            exit 1
        fi
        echo -e "${GREEN}--> ✅ 服务已成功初始化并响应。${NC}"
    else
         echo -e "${GREEN}--> ✅ 服务响应正常。${NC}"
    fi

    # 3. Apply the ultimate secure configuration.
    echo "--> 正在应用安全优化配置 (DoT, DNSSEC, No-LLMNR)..."
    # Use echo with a variable to write the multi-line configuration
    echo -e "${SECURE_RESOLVED_CONFIG}" > /etc/systemd/resolved.conf
    # Ensure the symlink is correct
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
    sleep 1
    echo -e "${GREEN}--> ✅ DNS 安全配置已应用并重启服务。${NC}"

    # 4. Final verification.
    echo -e "\n${GREEN}✅ 全部操作完成！以下是最终的 DNS 状态：${NC}"
    echo "----------------------------------------------------"
    resolvectl status
    echo "----------------------------------------------------"
    echo -e "${GREEN}请检查上面的 'DNS Servers' 是否为 '${TARGET_DNS}' 并确认 'DNSSEC' 和 'DNSOverTLS' 的状态。${NC}"
}


# --- Main Logic ---
main() {
    # 1. Check for root privileges first.
    if [[ $EUID -ne 0 ]]; then
       echo -e "${RED}错误: 此脚本必须以 root 用户身份运行。请使用 'sudo'。${NC}" >&2
       exit 1
    fi

    # =====================================================================
    #  Primary Fork: Is systemd-resolved active?
    # =====================================================================
    if command -v resolvectl &> /dev/null && resolvectl status &> /dev/null; then
        # --- PIPELINE A: systemd-resolved is ACTIVE ---
        echo -e "--> ${GREEN}[管线A] 检测到 systemd-resolved 正在运行。正在检查其持久化配置...${NC}"
        
        local current_dns
        current_dns=$(resolvectl status | awk '/^Global$/,/^$/ {if (/DNS Servers:/) {sub("DNS Servers: ", ""); print}}' | tr -s ' ')
        
        # Check all security parameters for idempotency
        local current_llmnr
        current_llmnr=$(grep -E '^\s*LLMNR=' /etc/systemd/resolved.conf | tail -n1 | cut -d= -f2 || echo "default")
        local current_mdns
        current_mdns=$(grep -E '^\s*MulticastDNS=' /etc/systemd/resolved.conf | tail -n1 | cut -d= -f2 || echo "default")
        local current_dnssec
        current_dnssec=$(grep -E '^\s*DNSSEC=' /etc/systemd/resolved.conf | tail -n1 | cut -d= -f2 || echo "default")
        local current_dot
        current_dot=$(grep -E '^\s*DNSOverTLS=' /etc/systemd/resolved.conf | tail -n1 | cut -d= -f2 || echo "default")

        if [[ "${current_dns}" == "${TARGET_DNS}" ]] && \
           [[ "${current_llmnr,,}" == "no" ]] && \
           [[ "${current_mdns,,}" == "no" ]] && \
           [[ "${current_dnssec,,}" == "allow-downgrade" ]] && \
           [[ "${current_dot,,}" == "yes" ]]; then
            echo -e "\n${GREEN}✅ 状态完美！系统已应用最终的安全DNS配置。无需操作。${NC}"
            exit 0
        else
            echo -e "${YELLOW}--> 当前配置不符合最终安全目标。将自动执行净化与加固...${NC}"
            purify_and_harden_dns
        fi
    else
        # --- PIPELINE B: systemd-resolved is NOT ACTIVE ---
        echo -e "--> ${YELLOW}[管线B] systemd-resolved 未激活或未安装。正在检查 /etc/resolv.conf...${NC}"
        
        if [[ ! -f /etc/resolv.conf ]]; then
            echo -e "${YELLOW}报告: /etc/resolv.conf 文件不存在。${NC}"
        else
            local current_nameservers
            current_nameservers=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')
            
            local impurities
            impurities=$(grep -E '^(search|domain|options)' /etc/resolv.conf || true)

            echo -e "${GREEN}--- 报告 ---${NC}"
            echo "当前DNS服务器 (nameservers): ${YELLOW}${current_nameservers:-未设置}${NC}"
            if [[ -n "$impurities" ]]; then
                echo -e "检测到杂项配置 (search/domain/options):\n${YELLOW}${impurities}${NC}"
            else
                echo -e "检测到杂项配置: ${YELLOW}无${NC}"
            fi
            echo -e "${GREEN}------------${NC}"
        fi

        echo # Add a blank line for readability
        read -p "您是否要安装并配置 systemd-resolved 以应用最终的安全DNS方案？(y/N): " -r user_choice
        user_choice=${user_choice,,} 

        if [[ "$user_choice" == "y" || "$user_choice" == "yes" ]]; then
            purify_and_harden_dns
        else
            echo -e "${YELLOW}操作被用户取消。脚本退出。${NC}"
            exit 0
        fi
    fi
}

# --- Script Entrypoint ---
main "$@"
