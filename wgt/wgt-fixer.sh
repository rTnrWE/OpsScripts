
---

**`wgt-fixer.sh` 脚本完整代码:**

```bash
#!/bin/bash

#====================================================================================
# wgt-fixer.sh - fscarmen WARP Zero Trust Manual Fix & Injection Script
#
#   Description: This script allows you to manually input the correct Teams account
#                details (fetched by fscarmen) to fix the configuration files that
#                fail due to formatting issues from the API.
#   Author:      Gemini & Collaborator
#   Version:     4.0.0 (Final Realistic Version)
#
#   Usage:
#   1. Run 'warp a' from fscarmen, choose to change to Teams account via email.
#   2. After browser auth, fscarmen will display the Key, IPv6, and Client ID. COPY these values.
#   3. Abort the fscarmen script (press 'n' or Ctrl+C).
#   4. Run this script:
#   rm -f wgt-fixer.sh && wget -N "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/wgt/wgt-fixer.sh" && chmod +x wgt-fixer.sh && sudo ./wgt-fixer.sh
#
#====================================================================================

# --- 界面颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 全局变量 ---
FSCARMEN_DIR="/etc/wireguard"
FSCARMEN_ACCOUNT_DB="${FSCARMEN_DIR}/warp-account.conf"
FSCARMEN_WARP_CONF="${FSCARMEN_DIR}/warp.conf"
FSCARMEN_PROXY_CONF="${FSCARMEN_DIR}/proxy.conf"

# --- 工具函数 ---
info() { echo -e "${GREEN}[信息] $*${NC}"; }
warn() { echo -e "${YELLOW}[警告] $*${NC}"; }
error() { echo -e "${RED}[错误] $*${NC}"; exit 1; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "本脚本必须以root权限运行，请使用 'sudo ./wgt-fixer.sh'。"
    fi
}

check_fscarmen() {
    if [ ! -f "${FSCARMEN_DIR}/menu.sh" ]; then
        error "在 '${FSCARMEN_DIR}/menu.sh' 未找到fscarmen/warp-sh脚本，请先安装主脚本。"
    fi
    info "检测到fscarmen/warp-sh已安装。"
}

# --- 核心逻辑 ---

main() {
    clear
    echo "================================================================="
    echo "  wgt-fixer.sh - fscarmen WARP Zero Trust 手动修复注入脚本"
    echo "================================================================="
    echo
    
    check_root
    check_fscarmen
    
    warn "--------------------------- 操作流程 (SOP) ---------------------------"
    warn "1. 请先运行 'warp a'，选择变更到Teams账户，并完成浏览器验证。"
    warn "2. fscarmen脚本会显示 [Private key], [Address IPv6], [Client id]。"
    warn "3. 请将这三项信息【准确地复制】下来。"
    warn "4. 然后，在确认环节【放弃】fscarmen的后续操作 (按 'n' 或 Ctrl+C)。"
    warn "5. 最后，在本脚本的引导下，将复制的信息粘贴进来。"
    warn "----------------------------------------------------------------"
    echo
    read -rp "您理解并准备好开始了吗? [Y/n]: " confirm
    if [[ "${confirm}" =~ ^[nN]$ ]]; then
        echo "操作已取消。"
        exit 0
    fi

    # --- 获取用户输入 ---
    echo
    info "--- 步骤 1: 请粘贴 Private key ---"
    read -rp "Private key: " PRIVATE_KEY
    if [ -z "${PRIVATE_KEY}" ]; then error "Private key 不能为空。"; fi

    echo
    info "--- 步骤 2: 请粘贴 Address IPv6 ---"
    info "(请粘贴fscarmen显示的那串完整的、带有[]和:0/128的地址)"
    read -rp "Address IPv6: " ADDRESS_IPV6_RAW
    if [ -z "${ADDRESS_IPV6_RAW}" ]; then error "Address IPv6 不能为空。"; fi

    echo
    info "--- 步骤 3: 请粘贴 Client id ---"
    read -rp "Client id: " CLIENT_ID
    if [ -z "${CLIENT_ID}" ]; then error "Client id 不能为空。"; fi

    # --- 数据清洗 ---
    info "正在清洗数据..."
    # 从 "[2606...]:0/128" 中提取出干净的 "2606.../128"
    local ADDRESS_IPV6_CLEANED=$(echo "${ADDRESS_IPV6_RAW}" | sed -E 's/\[([^]]+)\].*/\1\/128/')
    if ! [[ "${ADDRESS_IPV6_CLEANED}" =~ ^[0-9a-fA-F:]+\/128$ ]]; then
        error "无法从您输入的IPv6地址中提取出有效格式，请检查输入。"
    fi
    info "IPv6 地址清洗成功: ${ADDRESS_IPV6_CLEANED}"

    # --- 注入配置 ---
    info "正在将干净的配置注入到fscarmen文件中 (只替换，不删除)..."

    # 1. 修复 warp.conf (全局模式配置文件)
    if [ -f "${FSCARMEN_WARP_CONF}" ]; then
        sed -i "s#^PrivateKey = .*#PrivateKey = ${PRIVATE_KEY}#" "${FSCARMEN_WARP_CONF}"
        sed -i "s#^Address = 2606.*#Address = ${ADDRESS_IPV6_CLEANED}#" "${FSCARMEN_WARP_CONF}"
        info "'${FSCARMEN_WARP_CONF}' 已修复。"
    else
        warn "'${FSCARMEN_WARP_CONF}' 未找到，跳过。"
    fi

    # 2. 修复 proxy.conf (SOCKS5模式配置文件)
    if [ -f "${FSCARMEN_PROXY_CONF}" ]; then
        sed -i "s#^PrivateKey = .*#PrivateKey = ${PRIVATE_KEY}#" "${FSCARMEN_PROXY_CONF}"
        sed -i "s#^Address = 2606.*#Address = ${ADDRESS_IPV6_CLEANED}#" "${FSCARMEN_PROXY_CONF}"
        info "'${FSCARMEN_PROXY_CONF}' 已修复。"
    else
        warn "'${FSCARMEN_PROXY_CONF}' 未找到，跳过。"
    fi
    
    # 3. 修复 warp-account.conf (JSON 数据库), 确保状态一致性
    if [ -f "${FSCARMEN_ACCOUNT_DB}" ]; then
        local temp_json
        temp_json=$(mktemp)
        
        jq --arg pk "$PRIVATE_KEY" \
           --arg v6 "$(echo $ADDRESS_IPV6_CLEANED | cut -d'/' -f1)" \
           '.private_key = $pk | .config.interface.addresses.v6 = $v6 | .account.account_type = "teams"' \
           "${FSCARMEN_ACCOUNT_DB}" > "${temp_json}" && mv "${temp_json}" "${FSCARMEN_ACCOUNT_DB}"
           
        info "'${FSCARMEN_ACCOUNT_DB}' 已修复 (已标记为teams账户)。"
    else
        warn "'${FSCARMEN_ACCOUNT_DB}' 未找到，跳过。"
    fi

    info "所有配置文件已成功修复！"
    
    # --- 重启服务 ---
    info "正在重启 wireproxy 服务以应用新配置..."

    # 重置systemd的失败计数器
    systemctl reset-failed wireproxy.service 2>/dev/null

    if systemctl list-units --full -all | grep -q 'wireproxy.service'; then
        systemctl restart wireproxy.service
        sleep 2 # 等待服务启动
        if systemctl is-active --quiet wireproxy.service; then
            info "wireproxy 服务已成功启动！"
        else
            error "wireproxy 服务重启失败。请手动运行 'systemctl status wireproxy.service' 检查错误，并确认您的输入无误。"
        fi
    else
        warn "未找到 wireproxy.service。请通过 'warp y' 手动启动。"
    fi
    
    echo
    info "================================================================="
    info " 修复流程执行完毕！"
    info " 您的fscarmen安装现在应该已成功切换到Zero Trust账户。"
    info " 您可以运行 'warp' 命令进入主菜单查看账户状态。"
    echo "================================================================="
}

# --- 脚本入口 ---
main
