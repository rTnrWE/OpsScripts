#!/usr/bin/env sh
#
# Name:         DNS-Pure-Alpine.sh
# Description:  The ultimate, stable, and resilient script that enforces the
#               optimal secure DNS configuration on Alpine Linux using Unbound.
#               It performs a comprehensive health check on all known conflict points.
# Author:       rTnrWE
# Version:      2.0 (The Guardian)
#
# Usage:
# curl -sSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/DNS-Pure/DNS-Pure-Alpine.sh | sh
#

# --- Script Configuration and Safety ---
set -eu

# --- Global Constants ---
readonly UNBOUND_CONFIG_FILE="/etc/unbound/unbound.conf"
readonly SECURE_UNBOUND_CONFIG="server:
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
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes
    auto-trust-anchor-file: \"/var/lib/unbound/root.key\"
    
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

log() { echo "${GREEN}--> $1${NC}"; }
log_warn() { echo "${YELLOW}--> $1${NC}"; }
log_error() { echo "${RED}--> $1${NC}" >&2; }

# The main function to install, repair, and configure Unbound
purify_and_harden_dns_alpine() {
    echo "\n--- 开始执行DNS净化与安全加固流程 (Unbound) ---"

    # --- STAGE 1: NEUTRALIZE CONFLICTS ---
    log "阶段一：正在清除所有潜在的DNS冲突源..."

    # 1a. Purge legacy DNS settings from /etc/network/interfaces
    interfaces_file="/etc/network/interfaces"
    if [ -f "$interfaces_file" ] && grep -qE '^[[:space:]]*dns-(nameservers|search|domain)' "$interfaces_file"; then
        log "正在净化 /etc/network/interfaces 中的厂商残留DNS配置..."
        sed -i -E 's/^[[:space:]]*(dns-(nameservers|search|domain).*)/# \1/' "$interfaces_file"
        log "${GREEN}✅ 旧有DNS配置已成功注释禁用。${NC}"
    fi

    # 1b. Tame the DHCP client (udhcpc is common in Alpine)
    # The default script is at /usr/share/udhcpc/default.script.
    # We can create a post-bound hook in /etc/udhcpc/bound to override DNS.
    # A simpler, more direct approach is just to control resolv.conf directly.

    # --- STAGE 2: INSTALL AND CONFIGURE UNBOUND ---
    log "阶段二：正在配置 Unbound..."

    if ! command -v unbound >/dev/null; then
        log "正在安装 unbound..."
        apk -U --no-cache add unbound
    fi

    log "正在应用 Unbound 安全优化配置 (DoT & DNSSEC)..."
    echo "${SECURE_UNBOUND_CONFIG}" > "${UNBOUND_CONFIG_FILE}"

    # --- STAGE 3: ENFORCE SYSTEM DNS ---
    log "阶段三：正在强制系统使用 Unbound..."
    
    # This ensures our setting has the highest priority
    echo "nameserver 127.0.0.1" > /etc/resolv.conf.head
    
    # This makes the change immediate and persistent
    resolvconf -u
    # Final forceful overwrite to ensure purity
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    
    log "正在启用并启动 unbound 服务..."
    rc-update add unbound default
    rc-service unbound restart

    # --- STAGE 4: FINAL VERIFICATION ---
    echo "\n${GREEN}✅ 全部操作完成！以下是最终的 DNS 状态：${NC}"
    echo "----------------------------------------------------"
    echo "最终 /etc/resolv.conf 内容:"
    cat /etc/resolv.conf
    echo "----------------------------------------------------"
    echo "\n正在使用 'nslookup' 进行一次真实的DoT+DNSSEC查询测试..."
    echo "注意：对于DNSSEC测试域名，返回 'SERVFAIL' 是 Unbound 严格验证模式下【正确】的行为。"
    nslookup sigok.verteiltesysteme.net 127.0.0.1
    echo "----------------------------------------------------"
    echo "${GREEN}请检查上面的 'nslookup' 输出是否表明查询是发往 'Server: 127.0.0.1'。${NC}"
}

# --- Main Logic ---
main() {
    if [ "$(id -u)" -ne 0 ]; then
       log_error "错误: 此脚本必须以 root 用户身份运行。"
       exit 1
    fi

    echo "--- 开始执行全面系统DNS健康检查 (Alpine) ---"
    
    is_perfect=true

    # Check 1: Unbound service status
    printf "1. 检查 Unbound 服务状态... "
    if ! rc-service unbound status &>/dev/null; then
        echo "${YELLOW}服务未运行。${NC}"
        is_perfect=false
    else
        echo "${GREEN}正在运行。${NC}"
    fi

    # Check 2: resolv.conf purity
    printf "2. 检查 /etc/resolv.conf 配置... "
    if [ ! -f /etc/resolv.conf ] || \
       ! grep -qE "^\s*nameserver\s+127\.0\.0\.1\s*$" /etc/resolv.conf || \
       grep -qE "^\s*nameserver\s+(?!127\.0\.0\.1)" /etc/resolv.conf; then
        echo "${YELLOW}配置不纯净或不正确。${NC}"
        is_perfect=false
    else
        echo "${GREEN}配置纯净。${NC}"
    fi

    # Check 3: Unbound config file
    printf "3. 检查 Unbound 配置文件... "
    if [ ! -f "${UNBOUND_CONFIG_FILE}" ] || \
       ! grep -q "ssl-upstream:\s*yes" "${UNBOUND_CONFIG_FILE}" &>/dev/null; then
        echo "${YELLOW}安全配置 (DoT) 未应用。${NC}"
        is_perfect=false
    else
        echo "${GREEN}安全配置已应用。${NC}"
    fi

    # Final Decision
    if [ "$is_perfect" = true ]; then
        echo "\n${GREEN}✅ 全面检查通过！系统DNS配置稳定且安全。无需任何操作。${NC}"
        exit 0
    else
        echo "\n${YELLOW}--> 一项或多项检查未通过。为了确保系统的长期稳定，将执行完整的净化与加固流程...${NC}"
        purify_and_harden_dns_alpine
    fi
}

# --- Script Entrypoint ---
main "$@"
