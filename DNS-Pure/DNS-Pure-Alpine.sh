#!/usr/bin/env sh
#
# Name:         DNS-Pure-Alpine.sh
# Description:  The ultimate, stable, and resilient script that enforces the
#               optimal secure DNS configuration on Alpine Linux using Unbound.
#               Version 2.2 provides the final, correct, and robust implementation.
# Author:       rTnrWE
# Version:      2.2 (The Final Alpine Chapter)
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

log() { printf -- "${GREEN}--> %s${NC}\n" "$1"; }
log_warn() { printf -- "${YELLOW}--> %s${NC}\n" "$1"; }
log_error() { printf -- "${RED}--> %s${NC}\n" "$1" >&2; }

# The main function to install, repair, and configure Unbound
purify_and_harden_dns_alpine() {
    printf "\n--- 开始执行DNS净化与安全加固流程 (Unbound) ---\n"

    interfaces_file="/etc/network/interfaces"
    if [ -f "$interfaces_file" ] && grep -qE '^[[:space:]]*dns-(nameservers|search|domain)' "$interfaces_file"; then
        log "正在净化 /etc/network/interfaces 中的厂商残留DNS配置..."
        sed -i -E 's/^[[:space:]]*(dns-(nameservers|search|domain).*)/# \1/' "$interfaces_file"
        log "${GREEN}✅ 旧有DNS配置已成功注释禁用。${NC}"
    fi

    if ! command -v unbound >/dev/null; then
        log "正在安装 unbound..."
        apk -U --no-cache add unbound
    fi

    log "正在应用 Unbound 安全优化配置 (DoT & DNSSEC)..."
    echo "${SECURE_UNBOUND_CONFIG}" > "${UNBOUND_CONFIG_FILE}"

    log "正在强制系统使用本地 Unbound 解析器..."
    echo "nameserver 127.0.0.1" > /etc/resolv.conf.head
    if command -v resolvconf >/dev/null; then
        resolvconf -u
    fi
    # Final forceful overwrite to ensure purity, works even if resolvconf is not installed
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    
    log "正在启用并启动 unbound 服务..."
    rc-update add unbound default
    rc-service unbound restart

    printf "\n${GREEN}✅ 全部操作完成！以下是最终的 DNS 状态：${NC}\n"
    printf -- "----------------------------------------------------\n"
    printf "最终 /etc/resolv.conf 内容:\n"
    cat /etc/resolv.conf
    printf -- "----------------------------------------------------\n"
    printf "\n正在使用 'nslookup' 进行一次真实的DoT+DNSSEC查询测试...\n"
    printf "注意：对于DNSSEC测试域名，返回 'SERVFAIL' 是 Unbound 严格验证模式下【正确】的行为。\n"
    nslookup sigok.verteiltesysteme.net 127.0.0.1
    printf -- "----------------------------------------------------\n"
}

# --- Main Logic ---
main() {
    if [ "$(id -u)" -ne 0 ]; then
       log_error "错误: 此脚本必须以 root 用户身份运行。"
       exit 1
    fi

    printf -- "--- 开始执行全面系统DNS健康检查 (Alpine) ---\n"
    
    is_perfect=true

    # Check 1: Unbound service status
    printf "1. 检查 Unbound 服务状态... "
    if ! rc-service unbound status &>/dev/null; then
        printf "${YELLOW}服务未运行。${NC}\n"
        is_perfect=false
    else
        printf "${GREEN}正在运行。${NC}\n"
    fi

    # Check 2: resolv.conf purity (Robust, POSIX-compliant check)
    printf "2. 检查 /etc/resolv.conf 配置... "
    resolv_file="/etc/resolv.conf"
    if [ ! -f "$resolv_file" ]; then
        printf "${YELLOW}文件不存在。${NC}\n"
        is_perfect=false
    else
        # It must contain 127.0.0.1, and the total number of nameservers must be exactly 1.
        has_localhost=$(grep -c "nameserver 127.0.0.1" "$resolv_file" || true) # Use || true to prevent exit on no match
        nameserver_count=$(grep -c "nameserver" "$resolv_file" || true)
        if [ "$has_localhost" -ne 1 ] || [ "$nameserver_count" -ne 1 ]; then
            printf "${YELLOW}配置不纯净（必须且仅有 'nameserver 127.0.0.1'）。${NC}\n"
            is_perfect=false
        else
            printf "${GREEN}配置纯净。${NC}\n"
        fi
    fi

    # Check 3: Unbound config file
    printf "3. 检查 Unbound 配置文件... "
    if [ ! -f "${UNBOUND_CONFIG_FILE}" ] || \
       ! grep -q "ssl-upstream:\s*yes" "${UNBOUND_CONFIG_FILE}" 2>/dev/null; then
        printf "${YELLOW}安全配置 (DoT) 未应用。${NC}\n"
        is_perfect=false
    else
        printf "${GREEN}安全配置已应用。${NC}\n"
    fi

    # Final Decision
    if [ "$is_perfect" = true ]; then
        printf "\n${GREEN}✅ 全面检查通过！系统DNS配置稳定且安全。无需任何操作。${NC}\n"
        exit 0
    else
        printf "\n${YELLOW}--> 一项或多项检查未通过。将执行完整的净化与加固流程...${NC}\n"
        purify_and_harden_dns_alpine
    fi
}

# --- Script Entrypoint ---
main "$@"
