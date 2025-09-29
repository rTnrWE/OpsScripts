#!/usr/bin/env bash
#
# Name:         DNS-Pure.sh
# Description:  An intelligent, idempotent, and resilient script that enforces
#               the optimal secure DNS configuration on Debian systems.
#               Version 2.8 fixes the final idempotency bug by sanitizing
#               all external command outputs before comparison.
# Author:       rTnrWE
# Version:      2.8
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

# Purges legacy DNS settings from /etc/network/interfaces
purge_legacy_dns_settings() {
    local interfaces_file="/etc/network/interfaces"
    if [[ -f "$interfaces_file" ]]; then
        if grep -qE '^[[:space:]]*dns-(nameservers|search|domain)' "$interfaces_file"; then
            echo "--> 正在净化 /etc/network/interfaces 中的厂商残留DNS配置..."
            sed -i -E 's/^[[:space:]]*(dns-(nameservers|search|domain).*)/# \1/' "$interfaces_file"
            echo -e "${GREEN}--> ✅ 旧有DNS配置已成功注释禁用。${NC}"
        fi
    fi
}

# The main function to install, repair, and configure systemd-resolved
purify_and_harden_dns() {
    echo -e "\n--- 开始执行DNS净化与安全加固流程 ---"

    local debian_version
    if [[ -f /etc/os-release ]]; then
        debian_version=$(grep "VERSION_ID" /etc/os-release | cut -d'=' -f2 | tr -d '"')
    else
        debian_version=$(cat /etc/debian_version | cut -d'.' -f1)
    fi

    if [[ "$debian_version" == "11" ]]; then
        echo "--> 检测到 Debian 11。将执行额外的兼容性修复..."
        if dpkg -s resolvconf &> /dev/null; then
            echo "--> 正在卸载冲突的 'resolvconf' 软件包..."
            apt-get remove -y resolvconf > /dev/null
            echo -e "${GREEN}--> ✅ 'resolvconf' 已成功卸载。${NC}"
        fi
        rm -f /etc/resolv.conf
    fi

    purge_legacy_dns_settings

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
    fi

    echo "--> 正在启用并启动 systemd-resolved 服务..."
    systemctl enable systemd-resolved
    systemctl start systemd-resolved

    echo "--> 正在确保 systemd-resolved 服务响应正常..."
    sleep 1
    if ! resolvectl status &> /dev/null; then
        echo -e "${YELLOW}--> 服务未响应。正在尝试强制重新初始化...${NC}"
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        systemctl restart systemd-resolved
        sleep 2
        
        if ! resolvectl status &> /dev/null; then
            echo -e "${RED}错误：强制初始化后服务仍然无响应。请手动排查。${NC}" >&2
            exit 1
        fi
        echo -e "${GREEN}--> ✅ 服务已成功初始化并响应。${NC}"
    else
         echo -e "${GREEN}--> ✅ 服务响应正常。${NC}"
    fi

    echo "--> 正在应用安全优化配置 (DoT, DNSSEC, No-LLMNR)..."
    echo -e "${SECURE_RESOLVED_CONFIG}" > /etc/systemd/resolved.conf
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
    sleep 1
    echo -e "${GREEN}--> ✅ DNS 安全配置已应用并重启服务。${NC}"

    echo -e "\n${GREEN}✅ 全部操作完成！以下是最终的 DNS 状态：${NC}"
    echo "----------------------------------------------------"
    resolvectl status
    echo "----------------------------------------------------"

    echo -e "\n${GREEN}--- 如何手动验证 ---${NC}"
    echo "您可以随时使用以下命令来检查系统的DNS状态："
    echo ""
    echo -e "${YELLOW}1. 查看 systemd-resolved 的详细状态:${NC}"
    echo "   resolvectl status"
    echo ""
    echo -e "${YELLOW}2. 检查 systemd-resolved 服务的运行情况:${NC}"
    echo "   systemctl status systemd-resolved"
    echo ""
    echo -e "${YELLOW}3. 查看最终的安全配置文件内容:${NC}"
    echo "   cat /etc/systemd/resolved.conf"
    echo ""
    echo -e "${YELLOW}4. 确认 /etc/resolv.conf 已被正确接管 (应指向 .../stub-resolv.conf):${NC}"
    echo "   ls -l /etc/resolv.conf"
    echo "----------------------------------------------------"
    echo -e "${YELLOW}注意：如果本次执行了净化或安装操作，建议重启 (reboot) VPS 以确保所有网络更改完全生效。${NC}"
}


# --- Main Logic ---
main() {
    if [[ $EUID -ne 0 ]]; then
       echo -e "${RED}错误: 此脚本必须以 root 用户身份运行。请使用 'sudo'。${NC}" >&2
       exit 1
    fi

    echo "--> 正在检查系统DNS配置是否符合最终安全目标..."
    
    local is_perfect=true
    if ! command -v resolvectl &> /dev/null || ! resolvectl status &> /dev/null; then
        is_perfect=false
    else
        local status_output
        status_output=$(resolvectl status)
        
        # BUG FIX v2.8: Sanitize all variables extracted from external commands to remove
        # invisible characters like carriage returns (\r) and trim whitespace.
        
        local current_dns
        current_dns=$(echo "${status_output}" | awk '
        /^Global/ { in_global=1 }
        in_global && /DNS Servers:/ { gsub(/^.*DNS Servers: /, ""); print; collecting=1; next }
        in_global && collecting && /^[ \t]+[#0-9a-fA-F:.]+/ { gsub(/^[ \t]+/, ""); print; next }
        in_global && collecting && /^[^ \t]/ { collecting=0 }
        in_global && /^[^ \t]/ && ! /Global/ { in_global=0 }
        ' | paste -sd ' ' | tr -d '\r' | xargs)
        
        if [[ "${current_dns}" != "${TARGET_DNS}" ]]; then
            is_perfect=false
        fi

        local global_protocols
        global_protocols=$(echo "${status_output}" | sed -n '/Global/,/^\s*$/p' | grep "Protocols:" | tr -d '\r' | xargs)

        if ! echo "${global_protocols}" | grep -q -- "-LLMNR" || \
           ! echo "${global_protocols}" | grep -q -- "-mDNS" || \
           ! echo "${global_protocols}" | grep -q -- "+DNSOverTLS"; then
            is_perfect=false
        fi

        # The DNSSEC string can have suffixes like /supported, so we check for the prefix.
        if ! echo "${status_output}" | grep -q "DNSSEC=allow-downgrade"; then
             is_perfect=false
        fi
    fi

    if [[ "$is_perfect" == true ]]; then
        echo -e "\n${GREEN}✅ 状态完美！系统已应用最终的安全DNS配置。无需任何操作。${NC}"
        exit 0
    else
        echo -e "${YELLOW}--> 当前配置不符合最终安全目标。将自动执行净化与加固...${NC}"
        purify_and_harden_dns
    fi
}

# --- Script Entrypoint ---
main "$@"
