#!/usr/bin/env bash
#
# Name:         DNS-Pure.sh
# Description:  The ultimate, stable, and resilient script that enforces the
#               optimal secure DNS configuration on Debian systems. It performs
#               a comprehensive health check on all known conflict points
#               and provides clear, unambiguous feedback.
# Author:       rTnrWE
# Version:      2.6 (The Guardian - Refined Communication)
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
readonly NC="\033[0m"

# --- Helper Functions ---

log() { echo -e "${GREEN}--> $1${NC}"; }
log_warn() { echo -e "${YELLOW}--> $1${NC}"; }
log_error() { echo -e "${RED}--> $1${NC}" >&2; }

# The main function to install, repair, and configure systemd-resolved
purify_and_harden_dns() {
    echo -e "\n--- 开始执行DNS净化与安全加固流程 ---"

    local debian_version
    debian_version=$(grep "VERSION_ID" /etc/os-release | cut -d'=' -f2 | tr -d '"' || echo "unknown")

    # --- STAGE 1: NEUTRALIZE CONFLICTS (The Core of Stability) ---
    log "阶段一：正在清除所有潜在的DNS冲突源..."

    # 1a. Tame the DHCP client
    local dhclient_conf="/etc/dhcp/dhclient.conf"
    if [[ -f "$dhclient_conf" ]]; then
        if ! grep -q "ignore domain-name-servers;" "$dhclient_conf" || ! grep -q "ignore domain-search;" "$dhclient_conf"; then
            log "正在驯服 DHCP 客户端 (dhclient)..."
            # Add a newline just in case the file doesn't end with one
            echo "" >> "$dhclient_conf"
            echo "ignore domain-name-servers;" >> "$dhclient_conf"
            echo "ignore domain-search;" >> "$dhclient_conf"
            log "${GREEN}✅ 已确保 'ignore' 指令存在于 ${dhclient_conf}${NC}"
        fi
    fi

    # 1b. Disable the problematic if-up.d script
    local ifup_script="/etc/network/if-up.d/resolved"
    if [[ -f "$ifup_script" ]] && [[ -x "$ifup_script" ]]; then
        log "正在禁用有冲突的 if-up.d 兼容性脚本..."
        chmod -x "$ifup_script"
        log "${GREEN}✅ 已移除 ${ifup_script} 的可执行权限。${NC}"
    fi

    # 1c. Purge legacy DNS settings from /etc/network/interfaces
    local interfaces_file="/etc/network/interfaces"
    if [[ -f "$interfaces_file" ]] && grep -qE '^[[:space:]]*dns-(nameservers|search|domain)' "$interfaces_file"; then
        log "正在净化 /etc/network/interfaces 中的厂商残留DNS配置..."
        sed -i -E 's/^[[:space:]]*(dns-(nameservers|search|domain).*)/# \1/' "$interfaces_file"
        log "${GREEN}✅ 旧有DNS配置已成功注释禁用。${NC}"
    fi
    
    # --- STAGE 2: INSTALL AND CONFIGURE SYSTEMD-RESOLVED ---
    log "阶段二：正在配置 systemd-resolved..."

    if ! command -v resolvectl &> /dev/null; then
        log "正在安装 systemd-resolved..."
        apt-get update -y > /dev/null
        apt-get install -y systemd-resolved > /dev/null
    fi
    
    if [[ "$debian_version" == "11" ]] && dpkg -s resolvconf &> /dev/null; then
        log "检测到 Debian 11 上的 'resolvconf'，正在卸载..."
        apt-get remove -y resolvconf > /dev/null
        rm -f /etc/resolv.conf
        log "${GREEN}✅ 'resolvconf' 已成功卸载。${NC}"
    fi

    log "正在启用并启动 systemd-resolved 服务..."
    systemctl enable systemd-resolved
    systemctl start systemd-resolved
    
    log "正在应用最终的DNS安全配置 (DoT, DNSSEC...)"
    echo -e "${SECURE_RESOLVED_CONFIG}" > /etc/systemd/resolved.conf
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
    sleep 1

    # --- STAGE 3: SAFELY RESTART NETWORKING ---
    log "阶段三：正在安全地重启网络服务以应用所有更改..."
    if systemctl is-enabled --quiet networking.service; then
        systemctl restart networking.service
        log "${GREEN}✅ networking.service 已安全重启。${NC}"
    fi
    
    # --- STAGE 4: FINAL VERIFICATION ---
    echo -e "\n${GREEN}✅ 全部操作完成！以下是最终的 DNS 状态：${NC}"
    echo "----------------------------------------------------"
    resolvectl status
    echo "----------------------------------------------------"
    echo -e "\n${GREEN}--- 如何手动验证 ---${NC}"
    echo "您可以随时使用以下命令来检查系统的DNS状态："
    echo -e "${YELLOW}1. 查看 systemd-resolved 的详细状态:${NC} resolvectl status"
    echo -e "${YELLOW}2. 检查 networking.service 是否正常运行:${NC} systemctl status networking.service"
    echo "----------------------------------------------------"
}


# --- Main Logic ---
main() {
    if [[ $EUID -ne 0 ]]; then
       log_error "错误: 此脚本必须以 root 用户身份运行。请使用 'sudo'。"
       exit 1
    fi

    echo "--- 开始执行全面系统DNS健康检查 ---"
    
    local is_perfect=true

    # Check 1: systemd-resolved live status
    echo -n "1. 检查 systemd-resolved 实时状态... "
    if ! command -v resolvectl &> /dev/null || ! resolvectl status &> /dev/null; then
        echo -e "${YELLOW}服务未运行或无响应。${NC}"
        is_perfect=false
    else
        local status_output
        status_output=$(resolvectl status)
        local current_dns
        current_dns=$(echo "${status_output}" | sed -n '/Global/,/^\s*$/{/DNS Servers:/s/.*DNS Servers:[[:space:]]*//p}' | tr -d '\r\n' | xargs)
        
        if [[ "${current_dns}" != "${TARGET_DNS}" ]] || \
           ! echo "${status_output}" | grep -q -- "-LLMNR" || \
           ! echo "${status_output}" | grep -q -- "-mDNS" || \
           ! echo "${status_output}" | grep -q -- "+DNSOverTLS" || \
           ! echo "${status_output}" | grep -q "DNSSEC=allow-downgrade"; then
            echo -e "${YELLOW}实时配置与安全目标不符。${NC}"
            is_perfect=false
        else
            echo -e "${GREEN}配置正确。${NC}"
        fi
    fi

    # Check 2: dhclient.conf for ignore directives
    echo -n "2. 检查 dhclient.conf 配置... "
    local dhclient_conf="/etc/dhcp/dhclient.conf"
    if [[ -f "$dhclient_conf" ]]; then
        if grep -q "ignore domain-name-servers;" "$dhclient_conf" && \
           grep -q "ignore domain-search;" "$dhclient_conf"; then
            echo -e "${GREEN}已净化。${NC}"
        else
            echo -e "${YELLOW}未发现 'ignore' 净化参数。${NC}"
            is_perfect=false
        fi
    else
        # If the file doesn't exist, it can't cause problems. Consider it "ok".
        echo -e "${GREEN}文件不存在，无需净化。${NC}"
    fi


    # Check 3: Conflicting if-up.d script
    echo -n "3. 检查 if-up.d 冲突脚本... "
    local ifup_script="/etc/network/if-up.d/resolved"
    if [[ ! -f "$ifup_script" ]] || [[ ! -x "$ifup_script" ]]; then
        echo -e "${GREEN}已禁用或不存在。${NC}"
    else
        echo -e "${YELLOW}脚本存在且可执行。${NC}"
        is_perfect=false
    fi

    # Final Decision
    if [[ "$is_perfect" == true ]]; then
        echo -e "\n${GREEN}✅ 全面检查通过！系统DNS配置稳定且安全。无需任何操作。${NC}"
        exit 0
    else
        echo -e "\n${YELLOW}--> 一项或多项检查未通过。为了确保系统的长期稳定，将执行完整的净化与加固流程...${NC}"
        purify_and_harden_dns
    fi
}

# --- Script Entrypoint ---
main "$@"
