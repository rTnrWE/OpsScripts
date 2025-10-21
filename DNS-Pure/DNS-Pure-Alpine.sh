#!/usr/bin/env sh
#
# Name:         DNS-Pure-Alpine.sh
# Description:  The final, correct, and direct script to enforce a pure
#               DNS-over-TLS (DoT) configuration on Alpine Linux using Stubby.
#               Version 3.4 fixes the last regex bug and improves user feedback.
# Author:       rTnrWE
# Version:      3.4 (The Final Truth)
#
# Usage:
# curl -sSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/DNS-Pure-Alpine.sh | sh
#

# --- Script Configuration and Safety ---
set -eu

# --- Global Constants ---
readonly STUBBY_CONFIG_FILE="/etc/stubby/stubby.yml"
readonly SECURE_STUBBY_CONFIG="resolution_type: GETDNS_RESOLUTION_STUB
dns_transport_list:
  - GETDNS_TRANSPORT_TLS
tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
tls_query_padding_blocksize: 128
edns_client_subnet_private: 1
round_robin_upstreams: 1
idle_timeout: 10000
listen_addresses:
  - 127.0.0.1
  - 0::1
upstream_recursive_servers:
  # Google
  - address_data: 8.8.8.8
    tls_auth_name: \"dns.google\"
  - address_data: 8.8.4.4
    tls_auth_name: \"dns.google\"
  # Cloudflare
  - address_data: 1.1.1.1
    tls_auth_name: \"cloudflare-dns.com\"
  - address_data: 1.0.0.1
    tls_auth_name: \"cloudflare-dns.com\"
  # Google IPv6
  - address_data: 2001:4860:4860::8888
    tls_auth_name: \"dns.google\"
  - address_data: 2001:4860:4860::8844
    tls_auth_name: \"dns.google\"
  # Cloudflare IPv6
  - address_data: 2606:4700:4700::1111
    tls_auth_name: \"cloudflare-dns.com\"
  - address_data: 2606:4700:4700::1001
    tls_auth_name: \"cloudflare-dns.com\"
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

# NEW: Function to generate the final status report
generate_status_report() {
    printf -- "\n--- DNS 最终状态报告 ---\n"
    
    # Check if a live query works
    if ! nslookup -timeout=5 google.com 127.0.0.1 >/dev/null 2>&1; then
        log_error "!!! 验证失败：本地解析器 (Stubby @ 127.0.0.1) 未能成功解析域名。!!!"
        printf -- "----------------------------------------------------\n"
        return 1
    fi
    
    printf -- "----------------------------------------------------\n"
    printf "${GREEN}本地解析器 (Stubby @ 127.0.0.1): ${BOLD_GREEN}工作正常${NC}\n"
    printf "${GREEN}resolv.conf 模式: ${BOLD_GREEN}stub (指向 127.0.0.1)${NC}\n\n"
    printf "${BOLD_GREEN}上游 DoT 服务器池 (Upstream DoT Servers):${NC}\n"
    printf -- "    8.8.8.8#dns.google\n"
    printf -- "    1.1.1.1#cloudflare-dns.com\n"
    printf -- "    (以及其他备用和IPv6地址)\n"
    printf -- "----------------------------------------------------\n"
    printf "${BOLD_GREEN}结论：系统所有DNS查询都将通过本地 Stubby, 加密后发送到上述服务器池之一。${NC}\n"
}


# The main function to install and configure Stubby
purify_with_stubby() {
    printf "\n--- 开始执行DNS净化与安全加固流程 (Stubby) ---\n"

    interfaces_file="/etc/network/interfaces"
    if [ -f "$interfaces_file" ] && grep -qE '^[[:space:]]*dns-(nameservers|search|domain)' "$interfaces_file"; then
        log "正在净化 /etc/network/interfaces 中的厂商残留DNS配置..."
        sed -i -E 's/^[[:space:]]*(dns-(nameservers|search|domain).*)/# \1/' "$interfaces_file"
        log "${GREEN}✅ 旧有DNS配置已成功注释禁用。${NC}"
    fi

    if ! command -v stubby >/dev/null; then
        log "正在安装 stubby..."
        apk -U --no-cache add stubby
    fi

    log "正在应用 Stubby 安全优化配置 (DoT)..."
    echo "${SECURE_STUBBY_CONFIG}" > "${STUBBY_CONFIG_FILE}"

    log "正在强制系统使用本地 Stubby 解析器..."
    echo "nameserver 127.0.0.1" > /etc/resolv.conf.head
    if command -v resolvconf >/dev/null; then
        resolvconf -u
    fi
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    
    log "正在启用并启动 stubby 服务..."
    rc-update add stubby default
    rc-service stubby restart
    
    # Wait a moment for stubby to establish upstream connections
    sleep 2
}

# --- Main Logic ---
main() {
    if [ "$(id -u)" -ne 0 ]; then
       log_error "错误: 此脚本必须以 root 用户身份运行。"
       exit 1
    fi

    printf -- "--- 开始执行全面系统DNS健康检查 (Stubby) ---\n"
    
    is_perfect=true

    printf "1. 检查 Stubby 服务状态... "
    if ! rc-service stubby status &>/dev/null; then
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
        # Robust, POSIX-compliant check
        has_localhost=$(grep -c "nameserver 127.0.0.1" "$resolv_file" || true)
        nameserver_count=$(grep -c "nameserver" "$resolv_file" || true)
        if [ "$has_localhost" -ne 1 ] || [ "$nameserver_count" -ne 1 ]; then
            printf "${YELLOW}配置不纯净。${NC}\n"
            is_perfect=false
        else
            printf "${GREEN}配置纯净。${NC}\n"
        fi
    fi
    
    if [ "$is_perfect" = true ]; then
        printf "\n${GREEN}✅ 全面检查通过！系统DNS配置稳定且安全。${NC}\n"
        generate_status_report
        exit 0
    else
        printf "\n${YELLOW}--> 检查未通过。将执行完整的净化与加固流程...${NC}\n"
        purify_with_stubby
        generate_status_report
    fi
}

main "$@"
