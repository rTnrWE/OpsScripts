#!/usr/bin/env sh
#
# Name:         DNS-Pure-Alpine.sh
# Description:  The final, correct, and direct script to enforce a pure
#               DNS-over-TLS (DoT) configuration on Alpine Linux using Stubby.
#               Version 3.3 provides a clear, resolvectl-like final report.
# Author:       rTnrWE
# Version:      3.3 (The Final Report)
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

    # --- STAGE 1: CLEANUP ---
    log "阶段一：正在清理旧有配置和冲突软件..."
    
    if command -v unbound >/dev/null; then
        log "检测到已安装的 Unbound，正在卸载..."
        rc-service unbound stop &>/dev/null || true
        apk del unbound unbound-libs &>/dev/null || true
        log "${GREEN}✅ Unbound 已成功卸载。${NC}"
    fi

    interfaces_file="/etc/network/interfaces"
    if [ -f "$interfaces_file" ] && grep -qE '^[[:space:]]*dns-(nameservers|search|domain)' "$interfaces_file"; then
        log "正在净化 /etc/network/interfaces 中的厂商残留DNS配置..."
        sed -i -E 's/^[[:space:]]*(dns-(nameservers|search|domain).*)/# \1/' "$interfaces_file"
        log "${GREEN}✅ 旧有DNS配置已成功注释禁用。${NC}"
    fi

    # --- STAGE 2: INSTALL AND CONFIGURE STUBBY ---
    log "阶段二：正在安装并配置 Stubby..."
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

    # --- STAGE 3: VERIFICATION ---
    printf "\n${BOLD_GREEN}✅ 全部操作完成！正在进行最终状态验证...${NC}\n"
    # Wait a moment for stubby to establish upstream connections
    sleep 2

    # Perform a test query. We only care if it succeeds or fails.
    if ! nslookup -timeout=5 google.com 127.0.0.1 >/dev/null 2>&1; then
        log_error "!!! 验证失败：本地解析器 (Stubby @ 127.0.0.1) 未能成功解析域名。!!!"
        log_error "请检查 stubby 服务日志: logread | grep stubby"
        exit 1
    fi

    # If the test passes, print our custom, clear status report.
    printf -- "----------------------------------------------------\n"
    printf "${GREEN}本地解析器 (Stubby @ 127.0.0.1): ${BOLD_GREEN}工作正常${NC}\n"
    printf "${GREEN}resolv.conf 模式: ${BOLD_GREEN}stub (指向 127.0.0.1)${NC}\n\n"
    printf "${BOLD_GREEN}上游 DoT 服务器池 (Upstream DoT Servers):${NC}\n"
    printf -- "    8.8.8.8#dns.google\n"
    printf -- "    1.1.1.1#cloudflare-dns.com\n"
    printf -- "    8.8.4.4#dns.google\n"
    printf -- "    1.0.0.1#cloudflare-dns.com\n"
    printf -- "    (以及对应的 IPv6 地址)\n"
    printf -- "----------------------------------------------------\n"
    printf "${BOLD_GREEN}结论：系统所有DNS查询都将通过本地 Stubby, 加密后发送到上述服务器池之一。${NC}\n"
}

# --- Main Logic ---
main() {
    if [ "$(id -u)" -ne 0 ]; then
       log_error "错误: 此脚本必须以 root 用户身份运行。"
       exit 1
    fi

    # Simplified check: just check if stubby is the sole resolver.
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
    if [ ! -f "$resolv_file" ] || ! grep -qE "^\s*nameserver\s+127\.0.0\.1\s*$" "$resolv_file" || grep -qE "^\s*nameserver\s+(?!127\.0.0\.1)" "$resolv_file"; then
        printf "${YELLOW}配置不纯净。${NC}\n"
        is_perfect=false
    else
        printf "${GREEN}配置纯净。${NC}\n"
    fi
    
    if [ "$is_perfect" = true ]; then
        printf "\n${BOLD_GREEN}✅ 全面检查通过！系统DNS配置稳定且安全。无需任何操作。${NC}\n"
        exit 0
    else
        printf "\n${YELLOW}--> 检查未通过或状态不纯净。将执行完整的净化与加固流程...${NC}\n"
        purify_with_stubby
    fi
}

main "$@"
