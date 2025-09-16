#!/bin/bash

#================================================================================
# FILE:         sbvw.sh
# USAGE:        wget -N --no-check-certificate "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbvw.sh" && chmod +x sbvw.sh && ./sbvw.sh
# DESCRIPTION:  An all-in-one management platform for Sing-Box (VLESS+Reality+Vision),
#               supporting both standard and WARP outbounds.
#
# THANKS TO:    sing-box project: https://github.com/SagerNet/sing-box
#               fscarmen/warp project: https://gitlab.com/fscarmen/warp
#
# REVISION:     1.3
#================================================================================

SCRIPT_VERSION="1.3"
SCRIPT_URL="https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbvw.sh"
INSTALL_PATH="/root/sbvw.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
CONFIG_PATH="/etc/sing-box/config.json"
INFO_PATH_VRV="/etc/sing-box/vrv_info.env"
INFO_PATH_VRVW="/etc/sing-box/vrvw_info.env"
SINGBOX_BINARY=""
WARP_SCRIPT_URL="https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"

# Clean up terminal color on exit
trap 'echo -en "${NC}"' EXIT

check_root() { [[ "$EUID" -ne 0 ]] && { echo -e "${RED}错误：此脚本必须以 root 权限运行。${NC}"; exit 1; }; }

check_dependencies() {
    for cmd in curl jq openssl wget ping ss; do
        if ! command -v $cmd &> /dev/null; then
            echo "依赖 '$cmd' 未安装，正在尝试自动安装..."
            if command -v apt-get &> /dev/null; then apt-get update >/dev/null && apt-get install -y $cmd dnsutils iproute2
            elif command -v yum &> /dev/null; then yum install -y $cmd bind-utils iproute
            elif command -v dnf &> /dev/null; then dnf install -y $cmd bind-utils iproute
            else echo -e "${RED}无法确定包管理器。请手动安装 '$cmd'。${NC}"; exit 1; fi
            if ! command -v $cmd &> /dev/null; then echo -e "${RED}错误：'$cmd' 自动安装失败。${NC}"; exit 1; fi
        fi
    done
}

check_tfo_status() {
    if ! sysctl net.ipv4.tcp_fastopen | grep -q "3"; then
        echo -e "${RED}警告：检测到您的系统可能未开启 TCP Fast Open (TFO)。${NC}"
    fi
}

install_singbox_core() {
    echo ">>> 正在安装/更新 sing-box 最新稳定版..."
    if ! bash <(curl -fsSL https://sing-box.app/deb-install.sh); then echo -e "${RED}sing-box 核心安装失败。${NC}"; return 1; fi
    SINGBOX_BINARY=$(command -v sing-box)
    if [[ -z "$SINGBOX_BINARY" ]]; then echo -e "${RED}错误：未能找到 sing-box 可执行文件。${NC}"; return 1; fi
    echo -e "${GREEN}sing-box 核心安装成功！版本：$($SINGBOX_BINARY version | head -n 1)${NC}"
}

install_warp() {
    echo ">>> 正在下载并启动 WARP 管理脚本..."
    local warp_installer="/root/fscarmen-warp.sh"
    if ! wget -N "$WARP_SCRIPT_URL" -O "$warp_installer"; then
        echo -e "${RED}错误：下载 WARP 管理脚本失败。${NC}"
        return 1
    fi
    chmod +x "$warp_installer"
    clear
    echo "======================================================"
    echo -e "${GREEN}即将进入 fscarmen/warp 管理菜单。${NC}"
    echo "您的首要任务是安装 WireProxy。"
    echo -e "请在菜单中选择： ${GREEN}(5) 安装 WireProxy SOCKS5 代理${NC}"
    echo "按照脚本提示完成所有步骤，包括可能的 WARP+ 账户设置。"
    echo "完成后，此脚本将自动继续。"
    echo "======================================================"
    read -n 1 -s -r -p "按任意键继续..."
    
    bash "$warp_installer" w
    
    if ! systemctl is-active --quiet wireproxy; then
        echo -e "${RED}错误：检测到 WireProxy 服务未成功启动。${NC}"
        echo "请再次运行本脚本，选择 '6. 管理 WARP'，并确保 WireProxy 正常工作。"
        return 1
    fi
    echo -e "${GREEN}检测到 WireProxy 已成功安装并运行！${NC}"
    return 0
}

internal_validate_domain() {
    local domain="$1"
    echo -n "正在从 VPS 快速验证 ${domain} 的技术可用性... "
    if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 5 "https://${domain}" 2>&1 | grep -q "SSL connection using TLSv1.3"; then
        echo -e "${GREEN}成功！${NC}"; return 0
    else
        echo -e "${RED}失败！${NC}"; return 1
    fi
}

generate_config() {
    local outbound_type="$1" # "direct" or "warp"
    
    echo ">>> 正在配置 VLESS + Reality + Vision..."
    
    local listen_addr="::"
    local listen_port=443
    local co_exist_mode=false

    if ss -tlpn | grep -q ":${listen_port} "; then
        co_exist_mode=true
        listen_addr="127.0.0.1"
        echo "检测到 443 端口已被占用，将切换到“网站共存”模式。"
        read -p "请输入 sing-box 用于内部监听的端口 [默认 10443]: " custom_port
        listen_port=${custom_port:-10443}
    fi

    local handshake_server
    while true; do
        echo -en "${GREEN}"
        read -p "请输入 Reality 域名 [默认 www.bing.com]: " handshake_server
        echo -en "${NC}"
        handshake_server=${handshake_server:-www.bing.com}
        if internal_validate_domain "$handshake_server"; then
            break
        else
            echo -e "${RED}该域名技术上不可用。请选择另外一个。${NC}"
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
    
    local outbound_config
    if [[ "$outbound_type" == "warp" ]]; then
        outbound_config='{
          "type": "socks",
          "tag": "warp-out",
          "server": "127.0.0.1",
          "server_port": 40043,
          "version": "5",
          "tcp_fast_open": true
        }'
    else
        outbound_config='{
          "type": "direct",
          "tag": "direct",
          "tcp_fast_open": true
        }'
    fi

    jq -n \
      --arg listen_addr "$listen_addr" \
      --argjson listen_port "$listen_port" \
      --arg uuid "$uuid" \
      --arg server_name "$handshake_server" \
      --arg private_key "$private_key" \
      --arg short_id "$short_id" \
      --argjson outbound_config "$outbound_config" \
      '{
        "log": { "disabled": true },
        "inbounds": [
          {
            "type": "vless",
            "tag": "vless-in",
            "listen": $listen_addr,
            "listen_port": $listen_port,
            "sniff": true,
            "sniff_override_destination": true,
            "tcp_fast_open": true,
            "users": [ { "uuid": $uuid, "flow": "xtls-rprx-vision" } ],
            "tls": {
              "enabled": true,
              "server_name": $server_name,
              "reality": {
                "enabled": true,
                "handshake": { "server": $server_name, "server_port": 443 },
                "private_key": $private_key,
                "short_id": [ "", $short_id ]
              }
            }
          }
        ],
        "outbounds": [ $outbound_config ]
      }' > "$CONFIG_PATH"

    local info_file_path=$([[ "$outbound_type" == "warp" ]] && echo "$INFO_PATH_VRVW" || echo "$INFO_PATH_VRV")
    tee "$info_file_path" > /dev/null <<EOF
UUID=${uuid}
PUBLIC_KEY=${public_key}
SHORT_ID=${short_id}
HANDSHAKE_SERVER=${handshake_server}
LISTEN_PORT=443
CO_EXIST_MODE=${co_exist_mode}
INTERNAL_PORT=${listen_port}
EOF
    echo -e "${GREEN}配置文件及信息已保存。${NC}"
}

start_service() {
    echo ">>> 正在启动并设置 sing-box 开机自启..."
    systemctl daemon-reload; systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
    if systemctl is-active --quiet sing-box; then echo -e "${GREEN}sing-box 服务已成功启动！${NC}"; else echo -e "${RED}错误：sing-box 服务启动失败。${NC}"; return 1; fi
}

show_client_config_format() {
    if [[ ! -f "$1" ]]; then return; fi
    source "$1"
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
    local info_file_path="$1"
    if [[ ! -f "$info_file_path" ]]; then echo -e "${RED}错误：未找到配置信息文件。${NC}"; return; fi
    source "$info_file_path"
    
    local server_ip=$(curl -s4 icanhazip.com || curl -s6 icanhazip.com) || server_ip="[YOUR_SERVER_IP]"
    local vless_link="vless://${UUID}@${server_ip}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${HANDSHAKE_SERVER}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Sing-Box-VRV"

    echo -e "\n=================================================="
    if [[ "$info_file_path" == "$INFO_PATH_VRVW" ]]; then
        echo "    Sing-Box-(VLESS+Reality+Vision) WARP 出站配置    "
    else
        echo "    Sing-Box-(VLESS+Reality+Vision) 标准出站配置    "
    fi
    echo "=================================================="
    printf "  %-22s: ${GREEN}%s${NC}\n" "服务端配置文件" "$CONFIG_PATH"
    echo "--------------------------------------------------"
    echo -e "${GREEN}VLESS 导入链接:${NC}"
    echo "$vless_link"
    
    show_client_config_format "$info_file_path"

    if [[ "$CO_EXIST_MODE" == "true" ]]; then
        # ... (Co-exist mode instructions) ...
    else
        echo "--------------------------------------------------"
        echo "请在您自己的电脑上运行以下命令, 测试您本地到"
        echo "Reality 域名的真实网络延迟 (越低越好):"
        echo -e "${GREEN}ping ${HANDSHAKE_SERVER}${NC}"
        echo "--------------------------------------------------"
    fi
}

install_standard() {
    echo "--- 开始安装 Sing-Box-VRV (标准版) ---"
    rm -rf /etc/sing-box # Start fresh
    check_tfo_status
    install_singbox_core || return 1
    generate_config "direct" || return 1
    start_service || return 1
    show_summary "$INFO_PATH_VRV"
    echo -e "\n${GREEN}--- 标准版安装成功 ---${NC}"
}

install_with_warp() {
    echo "--- 开始安装 Sing-Box-VRV (WARP版) ---"
    rm -rf /etc/sing-box # Start fresh
    check_tfo_status
    install_warp || return 1
    install_singbox_core || return 1
    generate_config "warp" || return 1
    start_service || return 1
    show_summary "$INFO_PATH_VRVW"
    echo -e "\n${GREEN}--- WARP 版安装成功 ---${NC}"
}

upgrade_to_warp() {
    echo "--- 开始为现有 Sing-Box-VRV 添加 WARP 出站 ---"
    check_tfo_status
    install_warp || return 1
    
    echo ">>> 正在将您的 sing-box 配置升级为 WARP 出站..."
    warp_outbound=$(jq -n '{"type": "socks", "tag": "warp-out", "server": "127.0.0.1", "server_port": 40043, "version": "5", "tcp_fast_open": true}')
    jq --argjson new_outbound "$warp_outbound" '.outbounds = [$new_outbound]' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    if [[ $? -ne 0 ]]; then echo -e "${RED}错误：升级配置文件失败！${NC}"; return 1; fi
    
    if [[ -f "$INFO_PATH_VRV" ]]; then mv "$INFO_PATH_VRV" "$INFO_PATH_VRVW"; fi
    
    echo -e "${GREEN}配置文件升级成功！${NC}"
    
    systemctl restart sing-box; sleep 1
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}sing-box 服务已成功重启！${NC}"
        show_summary "$INFO_PATH_VRVW"
        echo -e "\n${GREEN}--- 升级成功 ---${NC}"
    else
        echo -e "${RED}错误：sing-box 服务重启失败。${NC}"; return 1
    fi
}

manage_service() {
    # ... (manage_service function, no changes needed) ...
}

uninstall_vrvw() {
    # ... (uninstall function, can be reused) ...
}

install_script_if_needed() {
    if [[ "$(realpath "$0")" != "$INSTALL_PATH" ]]; then
        echo ">>> 首次运行，正在安装管理脚本..."
        cp -f "$(realpath "$0")" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        echo -e "${GREEN}管理脚本已安装到 ${INSTALL_PATH}${NC}"
        echo "正在重新加载..."
        sleep 2
        exec bash "$INSTALL_PATH"
    fi
}

get_service_status() {
    local service_name="$1"
    local display_name="$2"
    if ! systemctl is-active --quiet "$service_name"; then
        printf "%-12s: %s\n" "$display_name" "$(echo -e ${RED}"已停止${NC}")"
    else
        printf "%-12s: %s\n" "$display_name" "$(echo -e ${GREEN}"运行中${NC}")"
    fi
}

main_menu() {
    install_script_if_needed
    
    while true; do
        clear
        local is_sbv_installed=$( [[ -f "$INFO_PATH_VRV" ]] && echo "true" || echo "false" )
        local is_sbvw_installed=$( [[ -f "$INFO_PATH_VRVW" ]] && echo "true" || echo "false" )
        
        echo "======================================================"
        echo "    Sing-Box VRV & WARP 统一管理平台 v${SCRIPT_VERSION}    "
        if [[ "$is_sbv_installed" == "true" || "$is_sbvw_installed" == "true" ]]; then
            echo "--------------------------------------------------"
            get_service_status "sing-box" "Sing-Box"
            if command -v warp &>/dev/null; then
                get_service_status "wireproxy" "WireProxy"
            fi
        fi
        echo "======================================================"
        echo "--- 安装选项 ---"
        echo " 1. 安装 Sing-Box (标准直连出站)"
        echo " 2. 安装 Sing-Box + WARP (WARP出站)"
        if [[ "$is_sbv_installed" == "true" ]]; then
            echo -e " 3. ${GREEN}为现有 Sing-Box 添加 WARP (升级)${NC}"
        fi
        echo "--- 管理选项 ---"
        echo " 4. 查看配置信息"
        echo " 5. 管理 sing-box 服务"
        echo " 6. 管理 WARP (调用 warp 命令)"
        echo "------------------------------------------------------"
        echo " 8. 检查脚本更新"
        echo " 9. 彻底卸载"
        echo " 0. 退出脚本"
        echo "======================================================"
        read -p "请输入你的选项: " choice

        case "${choice,,}" in
            1) install_standard; exit 0 ;;
            2) install_with_warp; exit 0 ;;
            3)
                if [[ "$is_sbv_installed" == "true" ]]; then
                    upgrade_to_warp
                    exit 0
                else
                    echo -e "\n${RED}无效选项。${NC}"
                    sleep 1
                fi
                ;;
            4) 
                if [[ "$is_sbv_installed" == "true" ]]; then show_summary "$INFO_PATH_VRV";
                elif [[ "$is_sbvw_installed" == "true" ]]; then show_summary "$INFO_PATH_VRVW";
                else echo -e "\n${RED}错误：请先安装。${NC}"; fi
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            5) if [[ -f "$CONFIG_PATH" ]]; then manage_service; else echo -e "\n${RED}错误：请先安装。${NC}"; fi ;;
            6) if command -v warp &>/dev/null; then warp; else echo -e "\n${RED}未检测到 warp 命令，请先安装 WARP。${NC}"; fi; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
            8) update_script; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
            9) uninstall_vrvw; exit 0 ;;
            0) exit 0 ;;
            *) echo -e "\n${RED}无效选项。${NC}"; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
        esac
    done
}

# --- Script Entry Point ---
check_root
check_dependencies
main_menu
