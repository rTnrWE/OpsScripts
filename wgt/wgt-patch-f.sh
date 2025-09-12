#!/bin/bash

#====================================================================================
# wgt-patch-f.sh - fscarmen WARP Zero Trust 账户修复补丁
#
#   Description: 本补丁脚本用于修复 fscarmen/warp-sh 脚本无法正确配置
#                Zero Trust (Teams) 账户的问题。它通过调用wgcf官方流程
#                获取可靠的配置信息，并将其注入到fscarmen的配置文件中。
#   Author:      Gemini 与 协作者
#   Version:     1.1.0
#
#   Usage:
#   wget -N --no-check-certificate "https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/wgt/wgt-patch-f.sh" && chmod +x wgt-patch-f.sh && sudo ./wgt-patch-f.sh
#
#====================================================================================

# --- 界面颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 全局变量 ---
SCRIPT_VERSION="1.1.0"
FSCARMEN_DIR="/etc/wireguard"
WGCF_PROFILE_PATH="${FSCARMEN_DIR}/wgcf-profile.conf"
WGCF_ACCOUNT_PATH="${FSCARMEN_DIR}/wgcf-account.toml" # 使用WGCF标准的账户文件
FSCARMEN_ACCOUNT_DB="${FSCARMEN_DIR}/warp-account.conf"
FSCARMEN_WARP_CONF="${FSCARMEN_DIR}/warp.conf"
FSCARMEN_PROXY_CONF="${FSCARMEN_DIR}/proxy.conf"

# --- 工具函数 ---
info() { echo -e "${GREEN}[信息] $*${NC}"; }
warn() { echo -e "${YELLOW}[警告] $*${NC}"; }
error() { echo -e "${RED}[错误] $*${NC}"; exit 1; }
pause_for_user() { read -rp "请按 [回车键] 继续..."; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "本脚本必须以root权限运行，请使用 'sudo ./wgt-patch-f.sh'。"
    fi
}

check_fscarmen() {
    if [ ! -f "${FSCARMEN_DIR}/menu.sh" ]; then
        error "在 '${FSCARMEN_DIR}/menu.sh' 未找到fscarmen/warp-sh脚本，请先安装主脚本。"
    fi
    info "检测到fscarmen/warp-sh已安装。"
}

install_dependency() {
    local dep_name=$1
    local pkg_name=$2
    local install_cmd=$3
    if ! command -v "$dep_name" &> /dev/null; then
        info "正在安装依赖: ${pkg_name}..."
        if ! ${install_cmd} > /dev/null 2>&1; then
            error "安装 ${pkg_name} 失败。请尝试运行 'apt-get update' 并手动安装。"
        fi
        info "${pkg_name} 安装成功。"
    fi
}

# --- 核心逻辑 ---

prepare_environment() {
    info "正在准备环境并安装必要的依赖..."
    install_dependency "wget" "wget" "apt-get update && apt-get install -y wget"
    install_dependency "jq" "jq" "apt-get install -y jq"
    
    if ! command -v "wgcf" &> /dev/null; then
        info "正在下载并安装 wgcf..."
        local arch
        case $(uname -m) in
            aarch64) arch="arm64" ;;
            x86_64) arch="amd64" ;;
            *) error "不支持的CPU架构: $(uname -m)" ;;
        esac
        if ! wget -O /usr/local/bin/wgcf "https://github.com/ViRb3/wgcf/releases/download/v2.2.19/wgcf_2.2.19_linux_${arch}"; then
             error "下载wgcf失败，请检查您的网络或稍后再试。"
        fi
        chmod +x /usr/local/bin/wgcf
        info "wgcf 安装成功。"
    fi
}

get_zero_trust_config() {
    info "开始获取官方Zero Trust配置..."
    warn "----------------------------------------------------------------"
    warn " 重要：此过程需要您从Cloudflare Zero Trust后台获取一个密钥。"
    warn "----------------------------------------------------------------"
    
    info "第 1 步: 注册一个空的WARP设备"
    wgcf register --accept-tos --config "${WGCF_ACCOUNT_PATH}"
    if [ $? -ne 0 ]; then
        error "wgcf注册免费账户失败，无法进行后续操作。"
    fi

    echo
    info "第 2 步: 获取您的Zero Trust密钥 (License Key)"
    info "   a. 在浏览器中登录您的Cloudflare Zero Trust控制台。"
    info "   b. 导航至 'My Team' -> 'Devices'。"
    info "   c. 点击 'Connect a device' 按钮。"
    info "   d. 在弹出的窗口中，找到并复制 'License' 字段下的那一长串密钥。"
    echo
    read -rp "请将您获取到的Zero Trust密钥粘贴到此处: " ZERO_TRUST_LICENSE
    if [ -z "${ZERO_TRUST_LICENSE}" ]; then
        error "密钥不能为空。"
    fi

    info "第 3 步: 将设备绑定到您的Zero Trust组织..."
    wgcf registration license --accept-tos --config "${WGCF_ACCOUNT_PATH}" "${ZERO_TRUST_LICENSE}"
    if [ $? -ne 0 ]; then
        error "设备绑定失败！请检查您的密钥是否正确，以及Zero Trust的设备注册策略是否已正确配置。"
    fi

    info "设备绑定成功！正在生成最终的WireGuard配置文件..."
    wgcf generate --config "${WGCF_ACCOUNT_PATH}" --profile "${WGCF_PROFILE_PATH}"
    if [ ! -s "${WGCF_PROFILE_PATH}" ]; then
        error "从账户数据生成WireGuard配置文件失败。"
    fi

    info "已成功获取官方认证的Zero Trust配置！"
}

patch_fscarmen_files() {
    info "正在解析干净的WireGuard配置文件..."
    
    local WGCF_PrivateKey=$(grep -oP 'PrivateKey = \K.*' "${WGCF_PROFILE_PATH}")
    local WGCF_AddressV4=$(grep 'Address = 172' "${WGCF_PROFILE_PATH}" | grep -oP 'Address = \K.*')
    local WGCF_AddressV6=$(grep 'Address = 2606' "${WGCF_PROFILE_PATH}" | grep -oP 'Address = \K.*')
    local WGCF_Endpoint=$(grep -oP 'Endpoint = \K.*' "${WGCF_PROFILE_PATH}")
    
    if [ -z "$WGCF_PrivateKey" ] || [ -z "$WGCF_AddressV6" ]; then
        error "从 '${WGCF_PROFILE_PATH}' 解析关键数据失败，文件可能已损坏。"
    fi
    
    info "正在将补丁应用到fscarmen的配置文件中..."

    # 补丁 1: 修复 warp.conf (wg-quick 全局模式)
    if [ -f "${FSCARMEN_WARP_CONF}" ]; then
        sed -i "s#^PrivateKey = .*#PrivateKey = ${WGCF_PrivateKey}#" "${FSCARMEN_WARP_CONF}"
        grep -q "^Address = 172" "${FSCARMEN_WARP_CONF}" && sed -i "s#^Address = 172.*#Address = ${WGCF_AddressV4}#" "${FSCARMEN_WARP_CONF}" || sed -i "/^PrivateKey = .*/a Address = ${WGCF_AddressV4}" "${FSCARMEN_WARP_CONF}"
        grep -q "^Address = 2606" "${FSCARMEN_WARP_CONF}" && sed -i "s#^Address = 2606.*#Address = ${WGCF_AddressV6}#" "${FSCARMEN_WARP_CONF}" || sed -i "/^Address = 172.*/a Address = ${WGCF_AddressV6}" "${FSCARMEN_WARP_CONF}"
        sed -i "s#^Endpoint = .*#Endpoint = ${WGCF_Endpoint}#" "${FSCARMEN_WARP_CONF}"
        info "'${FSCARMEN_WARP_CONF}' 已修复。"
    else
        warn "'${FSCARMEN_WARP_CONF}' 未找到，跳过。"
    fi

    # 补丁 2: 修复 proxy.conf (wireproxy SOCKS5 模式)
    if [ -f "${FSCARMEN_PROXY_CONF}" ]; then
        sed -i "s#^PrivateKey = .*#PrivateKey = ${WGCF_PrivateKey}#" "${FSCARMEN_PROXY_CONF}"
        grep -q "^Address = 172" "${FSCARMEN_PROXY_CONF}" && sed -i "s#^Address = 172.*#Address = ${WGCF_AddressV4}#" "${FSCARMEN_PROXY_CONF}" || sed -i "/^PrivateKey = .*/a Address = ${WGCF_AddressV4}" "${FSCARMEN_PROXY_CONF}"
        grep -q "^Address = 2606" "${FSCARMEN_PROXY_CONF}" && sed -i "s#^Address = 2606.*#Address = ${WGCF_AddressV6}#" "${FSCARMEN_PROXY_CONF}" || sed -i "/^Address = 172.*/a Address = ${WGCF_AddressV6}" "${FSCARMEN_PROXY_CONF}"
        sed -i "s#^Endpoint = .*#Endpoint = ${WGCF_Endpoint}#" "${FSCARMEN_PROXY_CONF}"
        info "'${FSCARMEN_PROXY_CONF}' 已修复。"
    else
        warn "'${FSCARMEN_PROXY_CONF}' 未找到，跳过。"
    fi

    # 补丁 3: 修复 warp-account.conf (JSON 数据库)
    if [ -f "${FSCARMEN_ACCOUNT_DB}" ]; then
        local temp_json
        temp_json=$(mktemp)
        
        jq --arg pk "$WGCF_PrivateKey" \
           --arg v4 "$(echo $WGCF_AddressV4 | cut -d'/' -f1)" \
           --arg v6 "$(echo $WGCF_AddressV6 | cut -d'/' -f1)" \
           --arg ep "$WGCF_Endpoint" \
           '.private_key = $pk | .config.interface.addresses.v4 = $v4 | .config.interface.addresses.v6 = $v6 | .config.peers[0].endpoint.host = $ep' \
           "${FSCARMEN_ACCOUNT_DB}" > "${temp_json}" && mv "${temp_json}" "${FSCARMEN_ACCOUNT_DB}"

        info "'${FSCARMEN_ACCOUNT_DB}' 已修复。"
    else
        warn "'${FSCARMEN_ACCOUNT_DB}' 未找到，跳过。"
    fi

    info "所有配置文件已成功修复！"
}

restart_services() {
    info "正在尝试重启WARP服务以应用新配置..."
    local is_restarted=false
    
    if systemctl list-units --full -all | grep -q 'wireproxy.service'; then
        if systemctl is-active --quiet wireproxy.service; then
            info "正在重启 wireproxy.service..."
            systemctl restart wireproxy.service
            is_restarted=true
        fi
    fi
    
    if systemctl list-units --full -all | grep -q 'wg-quick@warp.service'; then
        if systemctl is-active --quiet wg-quick@warp.service; then
            info "正在重启 wg-quick@warp.service..."
            systemctl restart wg-quick@warp.service
            is_restarted=true
        fi
    fi

    if [ "$is_restarted" = false ]; then
        warn "未找到正在运行的WARP服务 (wireproxy 或 wg-quick) 来重启。"
        warn "请通过fscarmen脚本手动运行 'warp o' 或 'warp y' 来启动服务。"
    else
        info "服务已重启。请等待几秒钟让连接建立。"
    fi
}

# --- 主逻辑 ---

main() {
    clear
    echo "================================================================="
    echo "  wgt-patch-f.sh - fscarmen WARP Zero Trust 账户修复补丁"
    echo "  版本: ${SCRIPT_VERSION}"
    echo "================================================================="
    echo
    
    check_root
    check_fscarmen
    
    echo
    warn "本脚本将引导您获取官方的Zero Trust账户配置，"
    warn "并将其应用到您现有的fscarmen安装中。"
    warn "这将会覆盖您当前的WARP账户信息。"
    echo
    pause_for_user
    
    prepare_environment
    get_zero_trust_config
    patch_fscarmen_files
    restart_services
    
    echo
    info "================================================================="
    info " 补丁流程执行完毕！"
    info " 您的fscarmen安装现在已使用官方认证的Zero Trust配置。"
    info " 请通过以下命令测试您的连接:"
    info " curl --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace"
    info " (如果您修改过SOCKS5端口，请替换40000)"
    echo "================================================================="
}

# --- 脚本入口 ---
main
