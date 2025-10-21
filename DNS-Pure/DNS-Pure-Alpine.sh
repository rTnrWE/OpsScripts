#!/usr/bin/env sh
#
# Name:         DNS-Pure-Alpine.sh
# Description:  The ultimate, stable, and resilient script that enforces the
#               optimal secure DNS configuration on Alpine Linux using Unbound.
#               Version 2.4 enhances user feedback during long operations.
# Author:       rTnrWE
# Version:      2.4 (The Final Alpine Chapter)
#
# Usage:
# curl -sSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/DNS-Pure/DNS-Pure-Alpine.sh | sh
#

# --- Script Configuration and Safety ---
set -eu

# --- Global Constants ---
readonly UNBOUND_CONFIG_FILE="/etc/unbound/unbound.conf"
readonly SECURE_UNBOUND_CONFIG="server:
    verbosity: 0
    interface: 127.0.0.1
    interface: ::1
    port: 53
    do-ip4: yes
    do-ip6: yes
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
readonly BOLD_GREEN="\033[1;32m"

# --- Helper Functions ---

log() { printf -- "${BOLD_GREEN}--> %s${NC}\n" "$1"; }
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
        log "正在安装 unbound (这可能需要一点时间)..."
        # Provide feedback for the installation process
        if apk -U --no-cache add unbound >/dev/null; then
            log "${GREEN}✅ unbound 安装成功。${NC}"
        else
            log_error "unbound 安装失败。请检查网络和apk配置。"
            exit 1
        fi
    fi
    
    log "正在创建 Unbound 数据目录..."
    mkdir -p "/var/lib/unbound/"

    # --- ENHANCED FEEDBACK FOR UNBOUND-ANCHOR ---
    log "正在初始化 DNSSEC 根信任锚 (root.key)..."
    log_warn "这一步需要连接网络，可能会持续 10-60 秒，请耐心等待..."
    
    # Execute and capture output/errors
    if unbound-anchor -a "/var/lib/unbound/root.key"; then
        log "${GREEN}✅ root.key 已成功生成。${NC}"
    else
        log_error "!!! 'unbound-anchor' 命令执行失败。!!!"
        log_error "这通常是由于网络问题或防火墙阻止了出站的 DNS/TLS 连接。"
        log_error "请检查您的网络连接和防火墙规则，然后重试。"
        exit 1
    fi

    log "正在应用 Unbound 安全优化配置 (DoT & DNSSEC)..."
    echo "${SECURE_UNBOUND_CONFIG}" > "${UNBOUND_CONFIG_FILE}"

    log "正在强制系统使用本地 Unbound 解析器..."
    echo "nameserver 127.0.0.1" > /etc/resolv.conf.head
    if command -v resolvconf >/dev/null; then
        resolvconf -u
    fi
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    
    log "正在启用并启动 unbound 服务..."
    rc-update add unbound default
    rc-service unbound restart

    printf "\n${BOLD_GREEN}✅ 全部操作完成！以下是最终的 DNS 状态：${NC}\n"
    printf -- "----------------------------------------------------\n"
    printf "最终 /etc/resolv.conf 内容:\n"
    cat /etc/resolv.conf
    printf -- "----------------------------------------------------\n"
    printf "\n正在使用 'nslookup' 进行一次真实的DoT查询测试 (查询 google.com)...\n"
    nslookup google.com 127.0.0.1
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

    printf "1. 检查 Unbound 服务状态... "
    if ! rc-service unbound status &>/dev/null; then
        printf "${YELLOW}服务未运行。${NC}\n"
        is_perfect=false
    else
        printf "${GREEN}正在运行。${NC}\n"
    fi

    printf "2. 检查 /etc/resolv.conf 配置... "
    resolv_file="/etc/resolv.conf"
    if [ ! -f "$resolv_file" ]; then
        printf "${YELLOW}文件不存在。${NC}\n"
        is_perfect=false
    else
        has_localhost=$(grep -c "nameserver 127.0.0.1" "$resolv_file" || true)
        nameserver_count=$(grep -c "nameserver" "$resolv_file" || true)
        if [ "$has_localhost" -ne 1 ] || [ "$nameserver_count" -ne 1 ]; then
            printf "${YELLOW}配置不纯净（必须且仅有 'nameserver 127.0.0.1'）。${NC}\n"
            is_perfect=false
        else
            printf "${GREEN}配置纯净。${NC}\n"
        fi
    fi

    printf "3. 检查 Unbound 配置文件... "
    if [ ! -f "${UNBOUND_CONFIG_FILE}" ] || \
       ! grep -q "ssl-upstream:\s*yes" "${UNBOUND_CONFIG_FILE}" 2>/dev/null; then
        printf "${YELLOW}安全配置 (DoT) 未应用。${NC}\n"
        is_perfect=false
    else
        printf "${GREEN}安全配置已应用。${NC}\n"
    fi

    if [ "$is_perfect" = true ]; then
        printf "\n${BOLD_GREEN}✅ 全面检查通过！系统DNS配置稳定且安全。无需任何操作。${NC}\n"
        exit 0
    else
        printf "\n${YELLOW}--> 一项或多项检查未通过。将执行完整的净化与加固流程...${NC}\n"
        purify_and_harden_dns_alpine
    fi
}

main "$@"
