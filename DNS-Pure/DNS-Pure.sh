#!/usr/bin/env bash
#
# Name:         DNS-Pure.sh
# Description:  The ultimate, idempotent, and resilient script that safely
#               upgrades the network management on Debian systems to the modern
#               systemd-networkd stack. It features a zero-risk, auto-rollback
#               mechanism and numerous hardening features to ensure stability.
# Author:       rTnrWE
# Version:      3.1 (The Final Chapter)
#
# Usage:
# curl -sSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/DNS-Pure/DNS-Pure.sh | sudo bash
#

# --- Script Configuration and Safety ---
set -euo pipefail

# --- Global Constants ---
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

run_upgrade_and_hardening() {
    echo -e "\n--- 开始执行网络架构升级与DNS加固流程 ---"

    # --- STAGE 1: PREPARATION & BACKUP ---
    log "阶段一：准备与备份..."
    
    local interface_name
    interface_name=$(ip -o -4 route show to default | awk '{print $5}')
    if [[ -z "$interface_name" ]]; then
        log_error "错误：无法自动检测到主网络接口。脚本中止。"
        exit 1
    fi
    log "自动检测到主网络接口为: ${YELLOW}${interface_name}${NC}"

    local ipv4_address
    ipv4_address=$(ip -o -4 addr show dev "$interface_name" | awk '{print $4}')
    if [[ -z "$ipv4_address" ]]; then
        log_error "错误：无法自动检测到IPv4地址。脚本中止。"
        exit 1
    fi
    log "自动检测到IPv4地址为: ${YELLOW}${ipv4_address}${NC}"

    local ipv4_gateway
    ipv4_gateway=$(ip -o -4 route show to default | awk '{print $3}')
    if [[ -z "$ipv4_gateway" ]]; then
        log_error "错误：无法自动检测到IPv4网关。脚本中止。"
        exit 1
    fi
    log "自动检测到IPv4网关为: ${YELLOW}${ipv4_gateway}${NC}"

    log "正在备份 /etc/network/interfaces..."
    cp -a /etc/network/interfaces "/etc/network/interfaces.dns-pure.bak.$(date +%F-%T)"

    local networkd_config_file="/etc/systemd/network/10-dns-pure.network"
    log "正在生成 systemd-networkd 配置文件..."
    
    local networkd_config="[Match]
Name=${interface_name}

[Network]
Address=${ipv4_address}
Gateway=${ipv4_gateway}
"
    local ipv6_address
    ipv6_address=$(ip -o -6 addr show dev "$interface_name" scope global | awk '{print $4}')
    local ipv6_gateway
    ipv6_gateway=$(ip -o -6 route show to default | awk '{print $3}')
    if [[ -n "$ipv6_address" ]] && [[ -n "$ipv6_gateway" ]]; then
        log "自动检测到IPv6配置，将一并迁移。"
        networkd_config+="Address=${ipv6_address}\nGateway=${ipv6_gateway}\n"
    fi

    # --- STAGE 2 & 3: CRITICAL SWITCH & HEALTH CHECK ---
    log "阶段二：尝试切换到 systemd-networkd..."
    
    systemctl stop networking.service

    echo -e "${networkd_config}" > "${networkd_config_file}"
    chmod 644 "${networkd_config_file}"
    systemctl start systemd-networkd
    
    sleep 5

    log "阶段三：执行在线健康检查..."
    local health_check_passed=true

    if ! networkctl status "$interface_name" | grep -q "State: configured"; then
        log_error "健康检查失败：接口 ${interface_name} 未能被 systemd-networkd 正确配置。"
        health_check_passed=false
    fi
    if ! ping -c 1 -W 3 "$ipv4_gateway" &> /dev/null; then
        log_error "健康检查失败：无法 Ping 通网关 ${ipv4_gateway}。"
        health_check_passed=false
    fi
    if ! ping -c 1 -W 3 "8.8.8.8" &> /dev/null; then
        log_error "健康检查失败：无法 Ping 通外部IP 8.8.8.8。"
        health_check_passed=false
    fi

    # --- STAGE 4: COMMIT OR ROLLBACK ---
    if [[ "$health_check_passed" == true ]]; then
        # --- SUCCESS PATH (COMMIT) ---
        log_warn "健康检查通过！网络已由 systemd-networkd 成功接管。现在将永久化配置。"
        
        systemctl disable networking.service
        systemctl mask networking.service
        systemctl enable systemd-networkd
        log "${GREEN}✅ 旧的 networking.service 已被永久禁用，systemd-networkd 已设为开机自启。${NC}"

        log "正在安装/配置 systemd-resolved..."
        systemctl enable systemd-resolved
        systemctl start systemd-resolved
        
        log "正在应用最终的DNS安全配置 (DoT, DNSSEC...)"
        echo -e "${SECURE_RESOLVED_CONFIG}" > /etc/systemd/resolved.conf
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        systemctl restart systemd-resolved
        
        echo -e "\n${GREEN}✅✅✅ 网络架构升级成功！✅✅✅${NC}"
        echo "----------------------------------------------------"
        resolvectl status
        echo "----------------------------------------------------"
        echo -e "${YELLOW}强烈建议您现在执行 'reboot' 来以全新的网络堆栈启动系统。${NC}"

    else
        # --- FAILURE PATH (ROLLBACK) ---
        log_error "!!! 切换失败，正在执行自动回滚 !!!"
        
        systemctl stop systemd-networkd &> /dev/null || true
        systemctl disable systemd-networkd &> /dev/null || true
        rm -f "${networkd_config_file}"
        
        # ULTIMATE HARDENING: Flush the interface to prevent "Address already assigned" error.
        log_warn "正在清理接口 ${interface_name} 上的残留IP配置..."
        ip addr flush dev "${interface_name}"
        
        log "正在尝试恢复旧的 networking.service..."
        systemctl start networking.service
        
        sleep 3
        if ping -c 1 "8.8.8.8" &> /dev/null; then
             echo -e "${GREEN}✅ 自动回滚成功！系统已恢复到之前的 networking.service 状态，网络连接已恢复。${NC}"
             echo -e "${GREEN}您的系统未做任何永久性更改。脚本已安全退出。${NC}"
        else
             log_error "!!! 紧急警告：自动回滚后网络连接仍未恢复。请通过VNC或控制台登录并执行 'reboot'。!!!"
             log_error "如果重启无效，请执行以下紧急救援命令替换<>内的内容:"
             log_error "ip addr add ${ipv4_address} dev ${interface_name}; ip route add default via ${ipv4_gateway}; echo 'nameserver 8.8.8.8' > /etc/resolv.conf"
        fi
        exit 1
    fi
}

main() {
    if [[ $EUID -ne 0 ]]; then
       log_error "错误: 此脚本必须以 root 用户身份运行。请使用 'sudo'。"
       exit 1
    fi

    echo "--> 正在检查系统网络管理状态..."
    
    if systemctl is-active --quiet systemd-networkd && ! systemctl is-enabled --quiet networking.service; then
        log "${GREEN}系统已由 systemd-networkd 管理。现在检查DNS配置...${NC}"
        
        local is_dns_perfect=true
        if ! command -v resolvectl &> /dev/null || ! resolvectl status &> /dev/null; then
            is_dns_perfect=false
        else
            local status_output
            status_output=$(resolvectl status)
            local current_dns
            current_dns=$(echo "${status_output}" | sed -n '/Global/,/^\s*$/{/DNS Servers:/s/.*DNS Servers:[[:space:]]*//p}' | tr -d '\r' | xargs)
            if [[ "${current_dns}" != "${TARGET_DNS}" ]]; then
                is_dns_perfect=false
            fi
        fi

        if [[ "$is_dns_perfect" == true ]]; then
            echo -e "\n${GREEN}✅ 状态完美！网络和DNS配置均符合最终目标。无需任何操作。${NC}"
            exit 0
        else
            log_warn "网络管理已是 systemd-networkd，但DNS配置不符。将仅执行DNS加固..."
            systemctl enable systemd-resolved
            systemctl start systemd-resolved
            echo -e "${SECURE_RESOLVED_CONFIG}" > /etc/systemd/resolved.conf
            ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
            systemctl restart systemd-resolved
            echo -e "\n${GREEN}✅ DNS配置已加固完成。${NC}"
        fi
    else
        log_warn "系统当前可能由 networking.service 管理。脚本将执行完整的、带回滚功能的网络架构升级。"
        run_upgrade_and_hardening
    fi
}

main "$@"
