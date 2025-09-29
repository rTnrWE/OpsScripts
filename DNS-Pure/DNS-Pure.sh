#!/usr/bin/env bash
#
# Name:         DNS-Pure.sh
# Description:  Checks the status of /etc/resolv.conf, reports its findings,
#               and asks for user confirmation before applying a persistent
#               DNS fix using systemd-resolved.
# Version:      2.1
# Usage:
# curl -sSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/DNS-Pure/DNS-Pure.sh | sudo bash
#

# --- Script Configuration and Safety ---
set -euo pipefail

# --- Global Constants ---
readonly TARGET_DNS="8.8.8.8 1.1.1.1"
readonly GREEN="\033[0;32m"
readonly YELLOW="\033[1;33m"
readonly RED="\033[0;31m"
readonly NC="\033[0m" # No Color

# --- Main Logic ---
main() {
    # 1. Check for root privileges first.
    if [[ $EUID -ne 0 ]]; then
       echo -e "${RED}错误: 此脚本必须以 root 用户身份运行。请使用 'sudo'。${NC}" >&2
       exit 1
    fi

    # =====================================================================
    # STAGE 1: Check and Report
    # =====================================================================
    echo "--> [阶段一] 正在检查 /etc/resolv.conf 的当前状态..."
    
    if [[ ! -f /etc/resolv.conf ]]; then
        echo -e "${YELLOW}报告: /etc/resolv.conf 文件不存在。${NC}"
    else
        local current_nameservers
        current_nameservers=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')
        
        local impurities
        impurities=$(grep -E '^(search|domain|options)' /etc/resolv.conf || true)

        echo -e "${GREEN}--- 报告 ---${NC}"
        echo "当前DNS服务器 (nameservers): ${YELLOW}${current_nameservers:-未设置}${NC}"
        if [[ -n "$impurities" ]]; then
            echo -e "检测到杂项配置 (search/domain/options):\n${YELLOW}${impurities}${NC}"
        else
            echo -e "检测到杂项配置: ${YELLOW}无${NC}"
        fi
        echo -e "${GREEN}------------${NC}"
    fi

    # =====================================================================
    # STAGE 2: User Confirmation
    # =====================================================================
    echo # Add a blank line for readability
    read -p "您是否要继续，使用 systemd-resolved 将DNS持久化设置为 [${TARGET_DNS}]？(y/N): " -r user_choice
    # Convert to lowercase
    user_choice=${user_choice,,} 

    if [[ "$user_choice" != "y" && "$user_choice" != "yes" ]]; then
        echo -e "${YELLOW}操作被用户取消。脚本退出。${NC}"
        exit 0
    fi
    
    # =====================================================================
    # STAGE 3: Action Phase (Only runs on user confirmation)
    # =====================================================================
    echo -e "\n--- 开始执行DNS净化流程 ---"

    # 1. Ensure systemd-resolved is installed.
    if ! command -v resolvectl &> /dev/null; then
        echo "--> 正在安装 systemd-resolved..."
        if ! apt-get update -y > /dev/null; then
            echo -e "${YELLOW}--> 'apt-get update' 失败，尝试通过 ntpdate 同步时间...${NC}"
            if apt-get install -y ntpdate > /dev/null && ntpdate -s time.google.com; then
                 echo -e "${GREEN}--> ✅ 系统时间已同步。${NC}"
            else
                 echo -e "${RED}--> 自动时间同步失败，请手动修复时间后重试。${NC}" >&2
                 exit 1
            fi
            apt-get update -y > /dev/null
        fi
        apt-get install -y systemd-resolved > /dev/null
        systemctl enable --now systemd-resolved
        echo -e "${GREEN}--> ✅ systemd-resolved 安装并启动成功。${NC}"
    fi

    # 2. Resiliency Check: Ensure the service is responsive, and auto-repair if not.
    echo "--> 正在确保 systemd-resolved 服务响应正常..."
    if ! resolvectl status &> /dev/null; then
        echo -e "${YELLOW}--> 服务未响应。正在尝试强制重新初始化...${NC}"
        systemctl stop systemd-resolved &> /dev/null || true
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        systemctl start systemd-resolved
        sleep 2
        
        if ! resolvectl status &> /dev/null; then
            echo -e "${RED}错误：强制初始化后服务仍然无响应。请手动排查。${NC}" >&2
            exit 1
        fi
        echo -e "${GREEN}--> ✅ 服务已成功初始化并响应。${NC}"
    else
         echo -e "${GREEN}--> ✅ 服务响应正常。${NC}"
    fi

    # 3. Apply new configuration.
    echo "--> 正在应用纯净DNS配置..."
    echo -e "[Resolve]\nDNS=${TARGET_DNS}\nDomains=" > /etc/systemd/resolved.conf
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
    sleep 1
    echo -e "${GREEN}--> ✅ DNS 配置修改并重启服务成功。${NC}"

    # 4. Final verification.
    echo -e "\n${GREEN}✅ 全部操作完成！以下是最终的 DNS 状态：${NC}"
    echo "----------------------------------------------------"
    resolvectl status
}

# --- Script Entrypoint ---
main "$@"
