#!/bin/bash

#================================================================================
# FILE:         sbv.sh
# USAGE:        wget -N --no-check-certificate "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbv.sh" && chmod +x sbv.sh && ./sbv.sh
# DESCRIPTION:  A dedicated management platform for Sing-Box (VLESS+Reality+Vision).
# REVISION:     4.8
#================================================================================

SCRIPT_VERSION="4.8"
SCRIPT_URL="https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbv.sh"
INSTALL_PATH="/root/sbv.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
CONFIG_PATH="/etc/sing-box/config.json"
INFO_PATH="/etc/sing-box/vrv_info.env"
SINGBOX_BINARY=""

check_root() { [[ "$EUID" -ne 0 ]] && { echo -e "${RED}错误：此脚本必须以 root 权限运行。${NC}"; exit 1; }; }

check_dependencies() {
    for cmd in curl jq openssl wget ping; do
        if ! command -v $cmd &> /dev/null; then
            echo "依赖 '$cmd' 未安装，正在尝试自动安装..."
            if command -v apt-get &> /dev/null; then apt-get update >/dev/null && apt-get install -y $cmd dnsutils
            elif command -v yum &> /dev/null; then yum install -y $cmd bind-utils
            elif command -v dnf &> /dev/null; then dnf install -y $cmd bind-utils
            else echo -e "${RED}无法确定包管理器。请手动安装 '$cmd'。${NC}"; exit 1; fi
            if ! command -v $cmd &> /dev/null; then echo -e "${RED}错误：'$cmd' 自动安装失败。${NC}"; exit 1; fi
        fi
    done
}

enable_tfo() {
    if sysctl net.ipv4.tcp_fastopen | grep -q "3"; then return 0; fi
    echo "net.ipv4.tcp_fastopen = 3" > /etc/sysctl.d/99-tcp-fastopen.conf
    sysctl -p /etc/sysctl.d/99-tcp-fastopen.conf >/dev/null 2>&1
    if sysctl net.ipv4.tcp_fastopen | grep -q "3"; then echo -e "${GREEN}TCP Fast Open (TFO) 已成功开启。${NC}"; else echo "警告：无法自动开启 TFO，可能会影响性能。"; fi
}

install_singbox_core() {
    echo ">>> 正在安装/更新 sing-box 最新稳定版..."
    if ! bash <(curl -fsSL https://sing-box.app/deb-install.sh); then echo -e "${RED}sing-box 核心安装失败。${NC}"; return 1; fi
    SINGBOX_BINARY=$(command -v sing-box)
    if [[ -z "$SINGBOX_BINARY" ]]; then echo -e "${RED}错误：未能找到 sing-box 可执行文件。${NC}"; return 1; fi
    echo -e "${GREEN}sing-box 核心安装成功！版本：$($SINGBOX_BINARY version | head -n 1)${NC}"
}

internal_validate_domain() {
    local domain="$1"
    echo -n "正在从 VPS 快速验证 ${domain} 的技术可用性... "
    if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 5 "https://domain}" 2>&1 | grep -q "SSL connection using TLSv1.3"; then
        echo -e "${GREEN}成功！${NC}"
        return 0
    else
        echo -e "${RED}失败！${NC}"; return 1
    fi
}

generate_config() {
    echo ">>> 正在配置 VLESS + Reality + Vision..."
    local handshake_server
    while true; do
        echo -en "${GREEN}"
        read -p "请输入 Reality 域名 [默认 www.microsoft.com]: " handshake_server
        echo -en "${NC}"
        handshake_server=${handshake_server:-www.microsoft.com}
        if internal_validate_domain "$handshake_server"; then
            break
        else
            echo -e "${RED}该域名技术上不可用。请选择一个能稳定访问的大厂域名。${NC}"
            read -p "是否 [R]重新输入 或 [Q]退出脚本? (R/Q): " choice
            case "${choice,,}" in
                q|quit) echo -e "${RED}安装已中止。${NC}"; return 1 ;;
                *) continue ;;
            esac
        fi
    done

    echo "正在生成密钥与 ID..."
    local key_pair=$($SINGBOX_BINARY generate reality-keypair)
    local private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    local public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    local uuid=$($SINGBOX_BINARY generate uuid)
    local short_id=$(openssl rand -hex 8)
    mkdir -p /etc/sing-box

    jq -n \
      --arg uuid "$uuid" \
      --arg server_name "$handshake_server" \
      --arg private_key "$private_key" \
      --arg short_id "$short_id" \
      '{
        "log": {
          "disabled": true
        },
        "dns": {
          "servers": [
            {
              "tag": "google",
              "address": "https://dns.google/dns-query",
              "detour": "direct"
            },
            {
              "tag": "cloudflare",
              "address": "https://cloudflare-dns.com/dns-query",
              "detour": "direct"
            }
          ],
          "strategy": "prefer_ipv4",
          "disable_cache": false
        },
        "inbounds": [
          {
            "type": "vless",
            "tag": "vless-in",
            "listen": "::",
            "listen_port": 443,
            "sniff": true,
            "sniff_override_destination": true,
            "tcp_fast_open": true,
            "users": [
              {
                "uuid": $uuid,
                "flow": "xtls-rprx-vision"
              }
            ],
            "tls": {
              "enabled": true,
              "server_name": $server_name,
              "reality": {
                "enabled": true,
                "handshake": {
                  "server": $server_name,
                  "server_port": 443
                },
                "private_key": $private_key,
                "short_id": [
                  "",
                  $short_id
                ]
              }
            }
          }
        ],
        "outbounds": [
          {
            "type": "direct",
            "tag": "direct"
          },
          {
            "type": "dns",
            "tag": "dns-out"
          }
        ],
        "route": {
          "final": "direct"
        }
      }' > "$CONFIG_PATH"

    tee "$INFO_PATH" > /dev/null <<EOF
UUID=${uuid}
PUBLIC_KEY=${public_key}
SHORT_ID=${short_id}
HANDSHAKE_SERVER=${handshake_server}
LISTEN_PORT=443
EOF
    echo -e "${GREEN}配置文件及信息已保存。${NC}"
}

start_service() {
    echo ">>> 正在启动并设置 sing-box 开机自启..."
    systemctl daemon-reload; systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
    if systemctl is-active --quiet sing-box; then echo -e "${GREEN}sing-box 服务已成功启动！${NC}"; else echo -e "${RED}错误：sing-box 服务启动失败。${NC}"; return 1; fi
}

show_client_config_format() {
    if [[ ! -f "$INFO_PATH" ]]; then return; fi
    source "$INFO_PATH"
    local server_ip=$(curl -s4 icanhazip.com || curl -s6 icanhazip.com) || server_ip="[YOUR_SERVER_IP]"
    
    echo "--------------------------------------------------"
    echo -e "${GREEN}客户端配置:${NC}"
    printf "  %-14s: %s\n" "server" "$server_ip"
    printf "  %-14s: %s\n" "port" "$LISTEN_PORT"
    printf "  %-14s: %s\n" "uuid" "$UUID"
    printf "  %-14s: %s\n" "flow" "xtls-rprx-vision"
    printf "  %-14s: %s\n" "servername" "$HANDSHAKE_SERVER"
    printf "  %-14s: %s\n" "public-key" "$PUBLIC_KEY"
    printf "  %-14s: %s\n" "short-id" "$SHORT_ID"
}

show_summary() {
    if [[ ! -f "$I
