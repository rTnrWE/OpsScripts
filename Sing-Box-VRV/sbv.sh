#!/bin/bash

#================================================================================
# FILE:         sbv.sh
# USAGE:        wget -N --no-check-certificate "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbv.sh" && chmod +x sbv.sh && ./sbv.sh
# DESCRIPTION:  A dedicated management platform for Sing-Box (VLESS+Reality+Vision).
# REVISION:     4.7
#================================================================================

SCRIPT_VERSION="4.7"
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
    if [[ ! -f "$INFO_PATH" ]]; then echo -e "${RED}错误：未找到配置信息文件。${NC}"; return; fi
    source "$INFO_PATH"
    local server_ip=$(curl -s4 icanhazip.com || curl -s6 icanhazip.com) || server_ip="[YOUR_SERVER_IP]"
    local vless_link="vless://${UUID}@${server_ip}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${HANDSHAKE_SERVER}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Sing-Box-VRV"

    echo -e "\n=================================================="
    echo "    Sing-Box-(VLESS+Reality+Vision) 配置    "
    echo "=================================================="
    printf "  %-22s: ${GREEN}%s${NC}\n" "服务端配置文件" "$CONFIG_PATH"
    echo "--------------------------------------------------"
    echo -e "${GREEN}VLESS 导入链接:${NC}"
    echo "$vless_link"
    
    show_client_config_format

    echo "--------------------------------------------------"
    echo "请在您自己的电脑上运行以下命令, 测试您本地到"
    echo "Reality 域名的真实网络延迟 (越低越好):"
    echo -e "${GREEN}ping ${HANDSHAKE_SERVER}${NC}"
    echo "--------------------------------------------------"
}

install_vrv() {
    # This function is now the single entry point for all install/reinstall actions
    if [[ -f "$CONFIG_PATH" ]]; then
        # Re-install logic
        echo "检测到已有安装。"
        read -p "请选择操作: [1] 沿用旧配置 (仅重装核心) [2] 全新配置 (将删除旧数据): " reinstall_choice
        case "$reinstall_choice" in
            1)
                echo "--- 正在使用旧配置重装核心 ---"
                install_singbox_core || { read -n 1 -s -r -p "按任意键返回主菜单..."; return 1; }
                start_service || { read -n 1 -s -r -p "按任意键返回主菜单..."; return 1; }
                show_summary
                echo -e "\n${GREEN}--- Sing-Box-VRV 核心重装成功 ---${NC}"
                ;;
            2)
                echo "--- 开始全新安装 (将覆盖旧数据) ---"
                rm -rf /etc/sing-box
                enable_tfo
                install_singbox_core || { read -n 1 -s -r -p "按任意键返回主菜单..."; return 1; }
                generate_config || { read -n 1 -s -r -p "按任意键返回主菜单..."; return 1; }
                start_service || { read -n 1 -s -r -p "按任意键返回主菜单..."; return 1; }
                show_summary
                echo -e "\n${GREEN}--- Sing-Box-VRV 全新安装成功 ---${NC}"
                ;;
            *)
                echo "操作已取消。"; return 0 ;;
        esac
    else
        # First-time install logic
        echo "--- 开始首次安装 Sing-Box-VRV ---"
        install_script_if_needed
        enable_tfo
        install_singbox_core || { read -n 1 -s -r -p "按任意键返回主菜单..."; return 1; }
        generate_config || { read -n 1 -s -r -p "按任意键返回主菜单..."; return 1; }
        start_service || { read -n 1 -s -r -p "按任意键返回主菜单..."; return 1; }
        show_summary
        echo -e "\n${GREEN}--- Sing-Box-VRV 安装成功 ---${NC}"
    fi
    
    echo -e "\n${GREEN}安装/重装流程已完成！${NC}"
    echo "您可以随时通过再次运行以下命令来管理平台："
    echo -e "${GREEN}./sbv.sh${NC}"
}

change_reality_domain() {
    local new_domain
    w
