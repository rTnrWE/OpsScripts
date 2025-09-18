#!/bin/bash

#===============================================================================
# wget -N --no-check-certificate "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbvw.sh" && chmod +x sbvw.sh && ./sbvw.sh
# Thanks: sing-box project (https://github.com/SagerNet/sing-box), fscarmen/warp-sh project (https://github.com/fscarmen/warp-sh)
#===============================================================================

SCRIPT_VERSION="2.4"
INSTALL_PATH="/root/sbvw.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
CONFIG_PATH="/etc/sing-box/config.json"
INFO_PATH_VRV="/etc/sing-box/vrv_info.env"
INFO_PATH_VRVW="/etc/sing-box/vrvw_info.env"
SINGBOX_BINARY=""
WARP_SCRIPT_URL="https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"

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
    if sysctl net.ipv4.tcp_fastopen | grep -q "3"; then
        echo -e "当前 TCP Fast Open (TFO) 状态: ${GREEN}已开启${NC}"
    else
        echo -e "当前 TCP Fast Open (TFO) 状态: ${RED}未开启${NC}"
        echo -e "${RED}警告：TFO 未开启可能会影响连接性能。${NC}"
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
        echo "请再次运行本脚本，选择 '7. 管理 WARP'，并确保 WireProxy 正常工作。"
        return 1
    fi
    echo -e "${GREEN}检测到 WireProxy 已成功安装并运行！${NC}"
    return 0
}

check_reality_domain() {
    local domain="$1"
    local success_count=0
    echo "正在检测 ${domain} 的 Reality 可用性（连续5次）..."
    for i in {1..5}; do
        if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 10 https://$domain 2>&1 | grep -q "SSL connection using TLSv1.3"; then
            echo -e "${GREEN}SUCCESS${NC}: $domain 第 $i 次检测通过。"
            ((success_count++))
        else
            echo -e "${RED}FAILURE${NC}: $domain 第 $i 次检测失败。"
        fi
        sleep 1
    done
    [[ $success_count -ge 4 ]]
}

generate_config() {
    local outbound_type="$1"
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
        echo -en "${GREEN}请输入 Reality 域名（示例：www.bing.com）: ${NC}"
        read handshake_server
        handshake_server=${handshake_server:-www.bing.com}
        if check_reality_domain "$handshake_server"; then
            echo -e "${GREEN}最终检测：$handshake_server 适合 Reality SNI，继续安装。${NC}"
            break
        else
            echo -e "${RED}检测未通过（连续5次至少通过4次才算合格）。请更换其它 Reality 域名。${NC}"
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

    # 配置文件日志功能始终关闭
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

    local info_file_path
    if [[ "$outbound_type" == "warp" ]]; then
        info_file_path="$INFO_PATH_VRVW"
    else
        info_file_path="$INFO_PATH_VRV"
    fi
    tee "$info_file_path" > /dev/null <<EOF
UUID=${uuid}
PUBLIC_KEY=${public_key}
SHORT_ID=${short_id}
HANDSHAKE_SERVER=${handshake_server}
LISTEN_PORT=443
CO_EXIST_MODE=${co_exist_mode}
INTERNAL_PORT=${listen_port}
EOF
    echo -e "${GREEN}配置文件及信息已保存（日志功能已关闭）。${NC}"
}

auto_disable_log_on_start() {
    if [[ -f "$CONFIG_PATH" ]]; then
        local log_disabled
        log_disabled=$(jq -r '.log.disabled' "$CONFIG_PATH")
        if [[ "$log_disabled" != "true" ]]; then
            jq '.log = {"disabled": true}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            systemctl restart sing-box
            echo -e "${GREEN}已自动关闭 sing-box 日志。${NC}"
        fi
    fi
}

view_log() {
    jq '.log = {"disabled": false}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    systemctl restart sing-box
    (
        trap 'jq ".log = {\"disabled\": true}" "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"; systemctl restart sing-box; exit' INT TERM EXIT TSTP
        echo -e "${GREEN}按 Ctrl+C 或 Ctrl+Z 可停止实时日志查看...${NC}"
        journalctl -u sing-box -f --no-pager
    )
    jq '.log = {"disabled": true}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    systemctl restart sing-box
}

check_and_toggle_log_status() {
    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e "${RED}未找到配置文件。${NC}"
        return
    fi
    local status=$(jq -r '.log.disabled' "$CONFIG_PATH")
    if [[ "$status" == "true" ]]; then
        read -p "按回车开启日志，输入 n 保持关闭: " ans
        if [[ -z "$ans" ]]; then
            jq '.log.disabled = false' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            systemctl restart sing-box
            echo -e "${RED}日志已开启。${NC}"
        else
            echo "保持日志已关闭。"
        fi
    else
        read -p "按回车关闭日志，输入 n 保持开启: " ans
        if [[ -z "$ans" ]]; then
            jq '.log.disabled = true' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            systemctl restart sing-box
            echo -e "${GREEN}日志已关闭。${NC}"
        else
            echo "保持日志已开启。"
        fi
    fi
    sleep 1
}

change_reality_domain() {
    while true; do
        echo -en "${GREEN}请输入新的 Reality 域名（示例：www.bing.com）: ${NC}"
        read new_domain
        new_domain=${new_domain:-www.bing.com}
        if check_reality_domain "$new_domain"; then
            echo -e "${GREEN}最终检测：$new_domain 非常适合 Reality SNI，将自动修改配置。${NC}"
            jq --arg new_domain "$new_domain" \
                '.inbounds[0].tls.server_name = $new_domain | .inbounds[0].tls.reality.handshake.server = $new_domain' \
                "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            systemctl restart sing-box
            echo -e "${GREEN}Reality 域名已更换并重启 sing-box。${NC}"
            break
        else
            echo -e "${RED}检测未通过（连续5次至少通过4次才算合格）。请更换其它 Reality 域名。${NC}"
            read -p "是否 [R]重新输入 或 [Q]返回菜单? (R/Q): " choice
            case "${choice,,}" in
                q|quit) return ;;
                *) continue ;;
            esac
        fi
    done
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
    local vless_link="vless://${UUID}@${server_ip}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${HANDSHAKE_SERVER}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none"

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
        echo "--------------------------------------------------"
        echo "您当前处于共存模式，sing-box 监听在内部端口 ${INTERNAL_PORT}，请确保您的反向代理或 Web 服务已正确配置。"
        echo "--------------------------------------------------"
    else
        echo "--------------------------------------------------"
        echo "请在您自己的电脑上运行以下命令, 测试您本地到 Reality 域名的真实网络延迟 (越低越好):"
        echo -e "${GREEN}ping ${HANDSHAKE_SERVER}${NC}"
        echo "--------------------------------------------------"
    fi
    echo -e "\n${GREEN}再次运行脚本管理：${NC}"
    echo -e "${GREEN}./sbvw.sh${NC}"
}

install_standard() {
    echo "--- 开始安装 Sing-Box-VRV (标准版) ---"
    rm -rf /etc/sing-box
    check_tfo_status
    install_singbox_core || return 1
    generate_config "direct" || return 1
    start_service || return 1
    show_summary "$INFO_PATH_VRV"
    echo -e "\n${GREEN}--- 标准版安装成功 ---${NC}"
}

install_with_warp() {
    echo "--- 开始安装 Sing-Box-VRV (WARP版) ---"
    rm -rf /etc/sing-box
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
    jq '.log = {"disabled": true}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    systemctl restart sing-box
    if [[ -f "$INFO_PATH_VRV" ]]; then mv "$INFO_PATH_VRV" "$INFO_PATH_VRVW"; fi
    echo -e "${GREEN}配置文件升级成功（日志功能已关闭）！${NC}"
    systemctl restart sing-box; sleep 1
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}sing-box 服务已成功重启！${NC}"
        show_summary "$INFO_PATH_VRVW"
        echo -e "\n${GREEN}--- 升级成功 ---${NC}"
    else
        echo -e "${RED}错误：sing-box 服务重启失败。${NC}"; return 1
    fi
}

update_script() {
    local temp_script_path="/root/sbvw.sh.new"
    if ! curl -fsSL "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbvw.sh" -o "$temp_script_path"; then
        echo -e "${RED}下载新版本脚本失败。${NC}"
        rm -f "$temp_script_path"
        return
    fi
    local new_version=$(grep 'SCRIPT_VERSION="' "$temp_script_path" | awk -F '"' '{print $2}')
    if [[ -z "$new_version" ]]; then
        echo -e "${RED}未检测到新脚本版本号，已中止更新。${NC}"
        rm -f "$temp_script_path"
        return
    fi
    if [[ "$SCRIPT_VERSION" != "$new_version" ]]; then
        read -p "$(echo -e ${GREEN}发现新版本 v${new_version}，是否更新? (y/N): ${NC})" confirm
        if [[ "${confirm,,}" != "n" ]]; then
            cat "$temp_script_path" > "$INSTALL_PATH"
            chmod +x "$INSTALL_PATH"
            rm -f "$temp_script_path"
            echo -e "${GREEN}脚本已成功更新至 v${new_version}！${NC}"
            echo "请重新运行 ./sbvw.sh 使用新版本。"
            exit 0
        else
            rm -f "$temp_script_path"
        fi
    else
        echo -e "${GREEN}脚本已是最新版本 (v${SCRIPT_VERSION})。${NC}"
        rm -f "$temp_script_path"
    fi
}

manage_service() {
    clear
    local log_status=$(jq -r '.log.disabled' "$CONFIG_PATH" 2>/dev/null)
    local log_menu=""
    if [[ "$log_status" == "true" ]]; then
        log_menu="${GREEN}6. 日志已关闭${NC}"
    else
        log_menu="${RED}6. 日志已开启${NC}"
    fi

    echo "--- sing-box 服务管理 ---"
    echo "-------------------------"
    echo " 1. 重启服务"
    echo " 2. 停止服务"
    echo " 3. 启动服务"
    echo " 4. 查看状态"
    echo " 5. 查看实时日志"
    echo " $log_menu"
    echo " 0. 返回主菜单"
    echo "-------------------------"
    read -p "请输入选项: " sub_choice
    case $sub_choice in
        1) systemctl restart sing-box; echo -e "${GREEN}sing-box 服务已重启。${NC}"; sleep 1 ;;
        2) systemctl stop sing-box; echo "sing-box 服务已停止。"; sleep 1 ;;
        3) systemctl start sing-box; echo -e "${GREEN}sing-box 服务已启动。${NC}"; sleep 1 ;;
        4) systemctl status sing-box; read -n 1 -s -r -p "按任意键返回服务菜单..." ;;
        5) view_log ;;
        6) check_and_toggle_log_status ;;
        0) return ;;
        *) echo -e "\n${RED}无效选项。${NC}"; sleep 1 ;;
    esac
}

uninstall_vrvw() {
    read -p "$(echo -e ${RED}"警告：此操作将卸载 sing-box 及本脚本。WARP 不会被卸载。要删除配置文件吗? [Y/n]: "${NC})" confirm_delete
    local keep_config=false
    if [[ "${confirm_delete,,}" == "n" ]]; then
        keep_config=true
    fi
    systemctl stop sing-box &>/dev/null; systemctl disable sing-box &>/dev/null
    local bin_path=$(command -v sing-box)
    if [[ "$keep_config" == false ]]; then
        echo "正在删除 sing-box 文件 (包括配置文件)..."
        rm -rf /etc/sing-box
    else
        echo "正在删除 sing-box 核心组件 (保留配置文件)..."
    fi
    rm -f /etc/systemd/system/sing-box.service
    if [[ -n "$bin_path" ]]; then rm -f "$bin_path"; fi
    systemctl daemon-reload; rm -f "$INSTALL_PATH"
    echo -e "${GREEN}Sing-Box-VRVW 已被移除。${NC}"
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
    auto_disable_log_on_start

    while true; do
        clear
        local is_sbv_installed=$([[ -f "$INFO_PATH_VRV" ]] && echo "true" || echo "false")
        local is_sbvw_installed=$([[ -f "$INFO_PATH_VRVW" ]] && echo "true" || echo "false")

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
        echo " 6. 更换 Reality 域名"
        echo " 7. 管理 WARP (调用 warp 命令)"
        echo "------------------------------------------------------"
        echo " 8. 更新脚本"
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
            6) change_reality_domain ;;
            7) if command -v warp &>/dev/null; then warp; else echo -e "\n${RED}未检测到 warp 命令，请先安装 WARP。${NC}"; fi; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
            8) update_script; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
            9) uninstall_vrvw; exit 0 ;;
            0) exit 0 ;;
            *) echo -e "\n${RED}无效选项。${NC}"; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
        esac
    done
}

check_root
check_dependencies
main_menu
