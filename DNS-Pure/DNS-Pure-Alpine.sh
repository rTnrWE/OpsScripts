#!/usr/bin/env sh
#
# Name:         DNS-Pure-Alpine.sh
# Description:  The final, correct, and direct script to enforce a pure
#               DNS-over-TLS (DoT) configuration on Alpine Linux using Stubby.
#               This version directly implements the user's core requirement.
# Author:       rTnrWE
# Version:      3.0 (The Stubby Way)
#
# Usage:
# curl -sSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/DNS-Pure/DNS-Pure-Alpine.sh | sh
#

# --- Script Configuration and Safety ---
set -eu

# --- Global Constants ---
readonly STUBBY_CONFIG_FILE="/etc/stubby/stubby.yml"
# This YAML config directly specifies the target DoT servers.
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
    # Final forceful overwrite to ensure purity
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    
    log "正在启用并启动 stubby 服务..."
    rc-update add stubby default
    rc-service stubby restart

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
        has_localhost=$(grep -c "nameserver 127.0.0.1" "$resolv_file" || true)
        nameserver_count=$(grep -c "nameserver" "$resolv_file" || true)
        if [ "$has_localhost" -ne 1 ] || [ "$nameserver_count" -ne 1 ]; then
            printf "${YELLOW}配置不纯净（必须且仅有 'nameserver 127.0.0.1'）。${NC}\n"
            is_perfect=false
        else
            printf "${GREEN}配置纯净。${NC}\n"
        fi
    fi

    if [ "$is_perfect" = true ]; then
        printf "\n${BOLD_GREEN}✅ 全面检查通过！系统DNS配置稳定且安全。无需任何操作。${NC}\n"
        exit 0
    else
        printf "\n${YELLOW}--> 一项或多项检查未通过。将执行完整的净化与加固流程...${NC}\n"
        purify_with_stubby
    fi
}

main "$@"
