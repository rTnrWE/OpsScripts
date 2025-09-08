#!/bin/bash

#================================================================================
# FILE:         sbv.sh
# USAGE:        wget -N --no-check-certificate "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbv.sh" && chmod +x sbv.sh && ./sbv.sh
# DESCRIPTION:  A dedicated management platform for Sing-Box (VLESS+Reality+Vision).
# REVISION:     3.9
#================================================================================

SCRIPT_VERSION="3.9"
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
    if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 5 "https://${domain}" 2>&1 | grep -q "SSL connection using TLSv1.3"; then
        echo -e "${GREEN}成功！${NC}"
        local ping_result=$(ping -c 3 -W 2 "$domain" | tail -1 | awk -F '/' '{print $5}')
        if [[ -n "$ping_result" ]]; then
            echo -e "从 VPS 到此域名的延迟约为: ${GREEN}${ping_result} ms${NC}"
        fi
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
        "log": { "disabled": true },
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
                "short_id": ["", $short_id]
              }
            }
          }
        ],
        "outbounds": [
          {
            "type": "direct",
            "tag": "direct",
            "tcp_fast_open": true,
            "domain_strategy": "prefer_ipv4"
          }
        ]
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
    echo "--------------------------------------------------"
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
}

install_vrv() {
    local first_time_install=false
    if [[ "$(realpath "$0")" != "$INSTALL_PATH" ]]; then
        first_time_install=true
    fi

    if [[ "$first_time_install" == false ]]; then
        echo "检测到已有安装。"
        read -p "请选择操作: [1] 沿用旧配置 (仅重装核心) [2] 全新配置 (将删除旧数据): " reinstall_choice
        case "$reinstall_choice" in
            1)
                echo "--- 正在使用旧配置重装核心 ---"
                enable_tfo
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
        echo "--- 开始首次安装 Sing-Box-VRV ---"
        install_script
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
    while true; do
        echo -en "${GREEN}"
        read -p "请输入新的 Reality 域名: " new_domain
        echo -en "${NC}"
        [[ -z "$new_domain" ]] && { echo -e "${RED}域名不能为空。${NC}"; continue; }
        if internal_validate_domain "$new_domain"; then
            break
        else
            echo -e "${RED}该域名技术上不可用。请选择一个能稳定访问的大厂域名。${NC}"
            read -p "是否 [R]重新输入 或 [Q]退出? (R/Q): " choice
            case "${choice,,}" in
                q|quit) echo -e "${RED}操作已中止。${NC}"; return ;;
                *) continue ;;
            esac
        fi
    done

    echo ">>> 正在更新配置文件..."
    jq --arg domain "$new_domain" '.inbounds[0].tls.server_name = $domain | .inbounds[0].tls.reality.handshake.server = $domain' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    if [[ $? -ne 0 ]]; then echo -e "${RED}错误：更新配置文件失败！${NC}"; return; fi
    sed -i "s/^HANDSHAKE_SERVER=.*/HANDSHAKE_SERVER=${new_domain}/" "$INFO_PATH"
    echo -e "${GREEN}配置文件已更新。${NC}"
    
    systemctl restart sing-box; sleep 1; echo -e "\n服务已重启，以下是您的新配置："
    show_summary
}

manage_service() {
    disable_logs_and_restart() {
        echo -e "\n>>> 正在关闭日志并恢复服务..."
        jq '.log = {"disabled": true}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
        systemctl restart sing-box
        echo -e "${GREEN}服务已恢复到无日志模式。${NC}"
    }
    
    clear
    echo "--- sing-box 服务管理 ---"
    echo "-------------------------"
    echo " 1. 重启服务"
    echo " 2. 停止服务"
    echo " 3. 启动服务"
    echo " 4. 查看状态"
    echo " 5. 查看实时日志 (临时开启)"
    echo " 0. 返回主菜单"
    echo "-------------------------"
    read -p "请输入选项: " sub_choice
    case $sub_choice in
        1) systemctl restart sing-box; echo -e "${GREEN}服务已重启。${NC}"; sleep 1 ;;
        2) systemctl stop sing-box; echo "服务已停止。"; sleep 1 ;;
        3) systemctl start sing-box; echo -e "${GREEN}服务已启动。${NC}"; sleep 1 ;;
        4) systemctl status sing-box ;;
        5) 
            echo -e "\n>>> 正在临时开启日志功能..."
            jq '.log = {"level": "info", "timestamp": true}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            systemctl restart sing-box
            echo -e "${GREEN}日志已临时开启。正在显示日志...${NC}"
            echo "按 Ctrl+C 即可停止查看并自动关闭日志。"
            sleep 2
            trap disable_logs_and_restart SIGINT
            journalctl -u sing-box -f --no-pager
            disable_logs_and_restart
            trap - SIGINT
            ;;
        *) return ;;
    esac
}

uninstall_vrv() {
    read -p "$(echo -e ${RED}"警告：此操作将彻底移除整个 Sing-Box-VRV 平台。要保留配置文件吗? [y/N]: "${NC})" confirm_keep
    local keep_config=false
    if [[ "${confirm_keep,,}" == "y" ]]; then
        keep_config=true
    fi
    
    systemctl stop sing-box &>/dev/null; systemctl disable sing-box &>/dev/null
    local bin_path=$(command -v sing-box)
    if [[ "$keep_config" == false ]]; then
        echo "正在删除所有文件..."
        rm -rf /etc/sing-box
    else
        echo "正在删除核心组件 (保留配置文件)..."
    fi
    rm -f /etc/systemd/system/sing-box.service
    if [[ -n "$bin_path" ]]; then rm -f "$bin_path"; fi
    systemctl daemon-reload; rm -f "$INSTALL_PATH"
    echo -e "${GREEN}Sing-Box-VRV 已被移除。${NC}"
}

install_script() {
    echo ">>> 正在安装管理脚本..."
    cp -f "$(realpath "$0")" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    echo -e "${GREEN}管理脚本已安装到 ${INSTALL_PATH}${NC}"
}

update_script() {
    echo ">>> 正在检查脚本更新..."
    local temp_script=$(mktemp)
    if ! curl -fsSL "$SCRIPT_URL" -o "$temp_script"; then echo -e "${RED}下载新版本脚本失败。${NC}"; rm "$temp_script"; return; fi
    if ! diff -q "$INSTALL_PATH" "$temp_script" &>/dev/null; then
        read -p "$(echo -e ${GREEN}"发现新版本，是否更新? (y/N): "${NC})" confirm
        if [[ "${confirm,,}" != "n" ]]; then
            mv "$temp_script" "$INSTALL_PATH"; chmod +x "$INSTALL_PATH"; echo -e "${GREEN}脚本已更新！正在重新加载...${NC}"; exec bash "$INSTALL_PATH"
        fi
    else
        echo -e "${GREEN}脚本已是最新版本。${NC}"; rm "$temp_script"
    fi
}

update_singbox_core() {
    install_singbox_core && systemctl restart sing-box && echo -e "${GREEN}sing-box 核心更新并重启成功！${NC}"
}

validate_reality_domain() {
    clear; echo "--- Reality 域名质量评估 ---";
    echo -en "${GREEN}"
    read -p "请输入你想测试的目标域名: " domain
    echo -en "${NC}"
    if [[ -z "$domain" ]]; then echo -e "\n${RED}域名不能为空。${NC}"; return; fi
    
    echo ""
    echo -n "正在从 VPS 测试技术可用性... "
    if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 5 "https://${domain}" 2>&1 | grep -q "SSL connection using TLSv1.3"; then
        echo -e "${GREEN}通过！${NC}"
        echo "--------------------------------------------------"
        echo "请在您自己的电脑 (例如 Windows CMD) 上运行以下命令, "
        echo "来测试您本地到此域名的真实网络延迟。"
        echo "延迟越低 (如低于100ms), 您的网络体验越好。"
        echo -e "${GREEN}ping ${domain}${NC}"
        echo "--------------------------------------------------"
    else
        echo -e "${RED}不通过！此域名不可用。${NC}"
    fi
}

main_menu() {
    clear
    echo "======================================================"
    echo "      Sing-Box-VRV v${SCRIPT_VERSION}      "
    echo "======================================================"
    if [[ ! -f "$CONFIG_PATH" ]]; then echo -e " 1. ${GREEN}安装 Sing-Box-VRV${NC}"; else echo -e " 1. ${GREEN}重新安装 Sing-Box-VRV${NC}"; fi
    echo " 2. 查看配置信息"
    echo " 3. 更换 Reality 域名"
    echo " 4. 管理 sing-box 服务"
    echo " 5. 验证 Reality 域名"
    echo "------------------------------------------------------"
    echo " 7. 更新 sing-box 核心"
    echo " 8. 检查脚本更新"
    echo " 9. 彻底卸载 Sing-Box-VRV"
    echo " 0. 退出脚本"
    echo "======================================================"
    read -p "请输入你的选项: " choice

    local is_installed=true
    if [[ ! -f "$CONFIG_PATH" && ",2,3,4,7," == *",${choice},"* ]]; then
        echo -e "\n${RED}错误：请先安装 Sing-Box-VRV (选项1)。${NC}"; is_installed=false
    fi

    if [[ "$is_installed" == true ]]; then
        case "${choice,,}" in
            1) install_vrv; exit 0 ;;
            2) show_summary ;;
            3) change_reality_domain ;;
            4) manage_service ;;
            5) validate_reality_domain ;;
            7) update_singbox_core ;;
            8) if [[ -f "$INSTALL_PATH" ]]; then update_script; else echo -e "${RED}脚本尚未安装，无法更新。${NC}"; fi ;;
            9) uninstall_vrv; exit 0 ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项。${NC}" ;;
        esac
    fi
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

check_root
check_dependencies
main_menu
