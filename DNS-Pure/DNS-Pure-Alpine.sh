#!/usr/bin/env sh
#
# Name:         DNS-Pure-Alpine.sh
# Description:  An assertive and idempotent script that enforces the optimal
#               secure DNS configuration on Alpine Linux using Unbound.
#               It automatically installs, repairs, and configures the system.
# Author:       rTnrWE
# Version:      1.0
#
# Usage:
# wget -O - https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/DNS-Pure/DNS-Pure-Alpine.sh | sudo sh
#  or
# curl -sSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/DNS-Pure/DNS-Pure-Alpine.sh | sudo sh
#

# --- Script Configuration and Safety ---
set -euo

# --- Global Constants ---
readonly TARGET_DNS_IPS="8.8.8.8 1.1.1.1" # Not used directly, but for reference
readonly UNBOUND_CONFIG_FILE="/etc/unbound/unbound.conf"
readonly SECURE_UNBOUND_CONFIG="server:
    # General server settings
    verbosity: 1
    interface: 127.0.0.1
    interface: ::1
    port: 53
    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes
    access-control: 127.0.0.0/8 allow
    access-control: ::1/128 allow
    
    # Performance settings
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes
    
    # Enable DNS over TLS (DoT)
    ssl-upstream: yes

# Forward all queries to secure DoT servers
forward-zone:
    name: \".\"
    forward-addr: 8.8.8.8@853#dns.google
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 2001:4860:4860::8888@853#dns.google
    forward-addr: 2606:4700:4700::1111@853#cloudflare-dns.com
"
readonly GREEN="\033[0;32m"
readonly YELLOW="\033[1;33m"
readonly RED="\033[0;31m"
readonly NC="\033[0m"

# --- Helper Functions ---

# Purges legacy DNS settings from /etc/network/interfaces
purge_legacy_dns_settings() {
    interfaces_file="/etc/network/interfaces"
    if [ -f "$interfaces_file" ]; then
        if grep -qE '^[[:space:]]*dns-(nameservers|search|domain)' "$interfaces_file"; then
            echo "--> 正在净化 /etc/network/interfaces 中的厂商残留DNS配置..."
            sed -i -E 's/^[[:space:]]*(dns-(nameservers|search|domain).*)/# \1/' "$interfaces_file"
            echo "${GREEN}--> ✅ 旧有DNS配置已成功注释禁用。${NC}"
        fi
    fi
}

# The main function to install, repair, and configure Unbound
purify_and_harden_dns_alpine() {
    echo "\n--- 开始执行DNS净化与安全加固流程 (Unbound) ---"

    # Purge legacy settings first
    purge_legacy_dns_settings

    # 1. Ensure Unbound and drill are installed.
    echo "--> 正在确保 unbound 和 ldns (drill) 已安装..."
    apk -U --no-cache add unbound ldns

    # 2. Apply the ultimate secure configuration.
    echo "--> 正在应用 Unbound 安全优化配置 (DoT)..."
    echo "${SECURE_UNBOUND_CONFIG}" > "${UNBOUND_CONFIG_FILE}"

    # 3. Force system to use Unbound.
    echo "--> 正在配置系统以使用本地 Unbound 解析器..."
    echo "nameserver 127.0.0.1" > /etc/resolv.conf.head
    # Update resolv.conf with the new head file
    resolvconf -u

    # 4. Enable and start the Unbound service.
    echo "--> 正在启用并启动 unbound 服务..."
    rc-update add unbound default
    rc-service unbound restart

    # 5. Final verification.
    echo "\n${GREEN}✅ 全部操作完成！Unbound 已配置为系统的安全DNS解析器。${NC}"
    echo "----------------------------------------------------"
    echo "验证 /etc/resolv.conf 内容:"
    cat /etc/resolv.conf
    echo "----------------------------------------------------"
    echo "\n正在使用 'drill' 进行一次真实的DoT查询测试..."
    drill sigok.verteiltesysteme.net @127.0.0.1
    echo "----------------------------------------------------"
    echo "${GREEN}请检查上面的 'drill' 命令输出是否包含 'HEADER' 和 'ANSWER SECTION'。${NC}"
    echo "${YELLOW}注意：如果本次执行了净化或安装操作，建议重启 (reboot) VPS 以确保所有网络更改完全生效。${NC}"
}

# --- Main Logic ---
main() {
    if [ "$(id -u)" -ne 0 ]; then
       echo "${RED}错误: 此脚本必须以 root 用户身份运行。${NC}" >&2
       exit 1
    fi

    echo "--> 正在检查系统DNS配置是否符合最终安全目标 (Unbound+DoT)..."
    
    is_perfect=true
    # Check 1: Is Unbound service running?
    if ! rc-service unbound status &> /dev/null; then
        is_perfect=false
    fi
    # Check 2: Is resolv.conf pointing to localhost?
    if ! grep -qE "^\s*nameserver\s+127\.0\.0\.1\s*$" /etc/resolv.conf || \
       grep -qE "^\s*nameserver\s+(?!127\.0\.0\.1)" /etc/resolv.conf; then
        is_perfect=false
    fi
    # Check 3: Does Unbound config contain our DoT settings?
    if ! grep -q "ssl-upstream:\s*yes" "${UNBOUND_CONFIG_FILE}" &> /dev/null; then
        is_perfect=false
    fi

    if [ "$is_perfect" = true ]; then
        echo "\n${GREEN}✅ 状态完美！系统已通过 Unbound 应用安全DNS配置。无需任何操作。${NC}"
        exit 0
    else
        echo "${YELLOW}--> 当前配置不符合最终安全目标。将自动执行净化与加固...${NC}"
        purify_and_harden_dns_alpine
    fi
}

# --- Script Entrypoint ---
main "$@"
