#!/usr/bin/env bash
#
# Name:         DNS-Pure.sh
# Description:  The ultimate, stable, and resilient script that enforces the
#               optimal secure DNS configuration on Debian systems by safely
#               integrating systemd-resolved with the existing networking service.
#               It focuses on neutralizing conflicts rather than replacing services.
# Author:       rTnrWE
# Version:      2.5
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
        log "正在驯服 DHCP 客户端 (dhclient)..."
        if ! grep -q "ignore domain-name-servers;" "$dhclient_conf"; then
            echo "ignore domain-name-servers;" >> "$dhclient_conf"
            log "${GREEN}✅ 已添加 'ignore domain-name-servers' 到 ${dhclient_conf}${NC}"
        fi
        if ! grep -q "ignore domain-search;" "$dhclient_conf"; then
            echo "ignore domain-search;" >> "$dhclient_conf"
            log "${GREEN}✅ 已添加 'ignore domain-search' 到 ${dhclient_conf}${NC}"
        fi
    fi

    # 1b. Disable the problematic if-up.d script
    local ifup_script="/etc/network/if-up.d/resolved"
    if [[ -x "$ifup_script" ]]; then
        log "正在禁用有冲突的 if-up.d 兼容性脚本..."
        chmod -x "$ifup_script"
        log "${GREEN}✅ 已移除 ${ifup_script} 的可执行权限。${NC}"
    fi

    # 1c. Purge legacy DNS settings from /etc/network/interfaces
    local interfaces_file="/etc/network/interfaces"
    if [[ -f "$interfaces_file" ]]; then
        if grep -qE '^[[:space:]]*dns-(nameservers|search|domain)' "$interfaces_file"; then
            log "正在净化 /etc/network/interfaces 中的厂商残留DNS配置..."
            sed -i -E 's/^[[:space:]]*(dns-(nameservers|search|domain).*)/# \1/' "$interfaces_file"
            log "${GREEN}✅ 旧有DNS配置已成功注释禁用。${NC}"
        fi
    fi
    
    # --- STAGE 2: INSTALL AND CONFIGURE SYSTEMD-RESOLVED ---
    log "阶段二：正在配置 systemd-resolved..."

    if ! command -v resolvectl &> /dev/null; then
        log "正在安装 systemd-resolved..."
        # Minimal apt-get update without full upgrade
        apt-get update -y > /dev/null
        apt-get install -y systemd-resolved > /dev/null
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
    # With all conflicts removed, this restart should now be safe.
    systemctl restart networking.service
    
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
    echo -e "${YELLOW}注意：为确保万无一失，建议您在方便时执行一次 'reboot'。${NC}"
}


# --- Main Logic ---
main() {
    if [[ $EUID -ne 0 ]]; then
       log_error "错误: 此脚本必须以 root 用户身份运行。请使用 'sudo'。"
       exit 1
    fi

    echo "--> 正在检查系统DNS配置是否符合最终安全目标..."
    
    local is_perfect=true
    if ! command -v resolvectl &> /dev/null || ! resolvectl status &> /dev/null; then
        is_perfect=false
    else
        local status_output
        status_output=$(resolvectl status)
        
        local current_dns
        current_dns=$(echo "${status_output}" | sed -n '/Global/,/^\s*$/{/DNS Servers:/s/.*DNS Servers:[[:space:]]*//p}' | tr -d '\r\n' | xargs)
        
        if [[ "${current_dns}" != "${TARGET_DNS}" ]]; then
            is_perfect=false
        fi

        local global_protocols
        global_protocols=$(echo "${status_output}" | sed -n '/Global/,/^\s*$/p' | grep "Protocols:" | tr -d '\r\n' | xargs)

        if ! echo "${global_protocols}" | grep -q -- "-LLMNR" || \
           ! echo "${global_protocols}" | grep -q -- "-mDNS" || \
           ! echo "${global_protocols}" | grep -q -- "+DNSOverTLS"; then
            is_perfect=false
        fi

        if ! echo "${status_output}" | grep -q "DNSSEC=allow-downgrade"; then
             is_perfect=false
        fi
    fi

    if [[ "$is_perfect" == true ]]; then
        echo -e "\n${GREEN}✅ 状态完美！系统已应用最终的安全DNS配置。无需任何操作。${NC}"
        exit 0
    else
        log_warn "当前配置不符合最终安全目标。将自动执行净化与加固..."
        purify_and_harden_dns
    fi
}

# --- Script Entrypoint ---
main "$@"
