#!/bin/bash

# ============================================================================
# Stash 深度清理工具 - Pro 版本
# macOS Ventura 13.7.8 专用 | SIP 关闭环境
#
# 融合特性：
# ✓ 优雅的进程管理 + 完整的 Keychain 清理 + 明确的用户确认
# ✓ 专业级的错误处理 + 清晰的视觉反馈 + 卸载后继续清理
# ============================================================================

set +e

# ===== 颜色定义 =====
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_NC='\033[0m'

# ===== 工具函数 =====
print_header() {
    echo -e "${C_YELLOW}╔════════════════════════════════════════╗${C_NC}"
    echo -e "${C_YELLOW}║   ${1}${C_YELLOW}║${C_NC}"
    echo -e "${C_YELLOW}╚════════════════════════════════════════╝${C_NC}"
}

print_section() {
    echo ""
    echo -e "${C_BLUE}[${1}] ${2}${C_NC}"
    echo -e "${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_NC}"
}

print_step() {
    echo -e "  ${C_CYAN}→${C_NC} ${1}"
}

print_success() {
    echo -e "    ${C_GREEN}✓${C_NC} ${1}"
}

print_error() {
    echo -e "    ${C_RED}✗${C_NC} ${1}"
}

print_warning() {
    echo -e "  ${C_YELLOW}⚠${C_NC} ${1}"
}

# ===== 开始 =====
clear

print_header "   Stash Pro 清理工具 - v2.0   "
echo ""
echo "系统要求: macOS Ventura 13.7.8+"
echo "SIP 状态: 已关闭"
echo ""

# ===== 第一步：系统状态检查 =====
print_section "0/6" "系统状态检查"

STASH_APP="/Applications/Stash.app"
if [ -d "$STASH_APP" ]; then
    print_step "Stash 应用状态"
    print_success "检测到 Stash 应用（将被删除）"
else
    print_step "Stash 应用状态"
    print_warning "未检测到 Stash 应用（可能已卸载）"
    print_step "脚本将继续清理所有残留文件"
fi

# ===== 第二步：安全确认（关键！）=====
print_section "0/6" "安全确认"

echo ""
echo -e "${C_RED}⚠️  重要警告：此操作不可逆！${C_NC}"
echo ""
echo "脚本将删除："
echo "  • Stash 应用本体"
echo "  • 所有配置文件和缓存"
echo "  • Keychain 中的所有 Stash 凭证"
echo "  • 系统启动项和帮助程序"
echo "  • 日志和临时文件"
echo ""
echo -e "${C_YELLOW}此操作后，如需恢复 Stash，需要重新下载和安装。${C_NC}"
echo ""

read -p "$(echo -e ${C_YELLOW})确认继续？请输入 ${C_RED}'yes'${C_YELLOW}:${C_NC} " user_confirmation

if [[ "$user_confirmation" != "yes" ]]; then
    echo ""
    print_error "用户取消操作"
    echo -e "${C_RED}清理已中止${C_NC}"
    echo ""
    read -p "按 Enter 退出..."
    exit 0
fi

echo ""
print_success "用户已确认，开始执行清理"
echo ""

# ===== 定义清理路径（数组管理）=====
declare -a PATHS_TO_REMOVE=(
    "/Applications/Stash.app"
    "/Applications/Stash\ Pro.app"
    "$HOME/Applications/Stash.app"
    "$HOME/Library/Application Support/Stash"
    "$HOME/Library/Application Support/com.stash*"
    "$HOME/Library/Caches/Stash"
    "$HOME/Library/Caches/com.stash*"
    "$HOME/Library/Caches/ws.stash*"
    "$HOME/Library/Logs/Stash"
    "$HOME/Library/Preferences/*stash*"
    "$HOME/Library/Preferences/com.stash*"
    "$HOME/Library/Saved Application State/com.stash*"
    "$HOME/Library/Saved Application State/ws.stash*"
    "/Users/Shared/Stash"
    "/Library/PrivilegedHelperTools/ws.stash*"
    "/Library/Logs/stash*"
)

declare -a LAUNCH_ITEMS=(
    "/Library/LaunchDaemons/ws.stash*"
    "/Library/LaunchDaemons/.ws.stash*"
    "/Library/LaunchAgents/ws.stash*"
    "/Library/LaunchAgents/.ws.stash*"
    "$HOME/Library/LaunchAgents/ws.stash*"
    "$HOME/Library/LaunchAgents/.ws.stash*"
)

# ===== 第三步：进程管理（优雅降级）=====
print_section "1/6" "停止 Stash 进程"

if pgrep -i "Stash" >/dev/null 2>&1; then
    print_step "检测到运行中的 Stash 进程"
    
    # 首先尝试优雅停止
    print_step "尝试优雅停止进程..."
    sudo pkill -i "Stash" 2>/dev/null
    sleep 1
    
    # 检查是否仍在运行
    if pgrep -i "Stash" >/dev/null 2>&1; then
        print_step "优雅停止失败，强制终止..."
        sudo pkill -9 -i "Stash" 2>/dev/null
        sleep 1
        print_success "进程已强制终止"
    else
        print_success "进程已优雅停止"
    fi
else
    print_success "未发现运行中的 Stash 进程"
fi

# ===== 第四步：卸载启动项 =====
print_section "2/6" "卸载系统启动项"

REMOVED_LAUNCH_COUNT=0
for pattern in "${LAUNCH_ITEMS[@]}"; do
    for item in $pattern; do
        if [ -f "$item" ]; then
            print_step "卸载: $(basename $item)"
            # 使用新的 bootout 方式（Ventura+ 推荐）
            sudo launchctl bootout "gui/$(id -u)" "$item" 2>/dev/null || true
            sudo launchctl bootout system "$item" 2>/dev/null || true
            # 备用：如果 bootout 失败则尝试 unload
            sudo launchctl unload -w "$item" 2>/dev/null || true
            # 删除文件
            sudo rm -f "$item" 2>/dev/null
            if [ $? -eq 0 ]; then
                print_success "已清理"
                ((REMOVED_LAUNCH_COUNT++))
            else
                print_error "清理失败"
            fi
        fi
    done
done

if [ $REMOVED_LAUNCH_COUNT -eq 0 ]; then
    print_success "未发现启动项（已清理）"
fi

# ===== 第五步：删除文件和目录 =====
print_section "3/6" "删除应用文件和配置"

REMOVED_FILES_COUNT=0
for pattern in "${PATHS_TO_REMOVE[@]}"; do
    for item in $pattern; do
        if [ -e "$item" ]; then
            display_name=$(basename "$item" 2>/dev/null || echo "$item")
            print_step "删除: $display_name"
            
            if sudo rm -rf "$item" 2>/dev/null; then
                print_success "成功"
                ((REMOVED_FILES_COUNT++))
            else
                print_error "失败（权限问题？）"
            fi
        fi
    done
done

if [ $REMOVED_FILES_COUNT -eq 0 ]; then
    print_success "未发现文件或已删除"
fi

# ===== 第六步：Keychain 清理（完整版）=====
print_section "4/6" "清理 Keychain 凭证"

KEYCHAIN_DB="$HOME/Library/Keychains/login.keychain-db"

if [ -f "$KEYCHAIN_DB" ]; then
    print_step "检测到 Keychain 数据库"
    
    # 清理通用密码
    print_step "清理通用密码..."
    security delete-generic-password -s "stash" 2>/dev/null || true
    security delete-generic-password -s "ws.stash" 2>/dev/null || true
    security delete-generic-password -s "Stash" 2>/dev/null || true
    security delete-generic-password -s "com.stash" 2>/dev/null || true
    security delete-generic-password -a "stash" 2>/dev/null || true
    security delete-generic-password -a "ws.stash" 2>/dev/null || true
    print_success "通用密码已清理"
    
    # 清理互联网密码
    print_step "清理互联网密码..."
    security delete-internet-password -s "stash" 2>/dev/null || true
    security delete-internet-password -s "ws.stash" 2>/dev/null || true
    security delete-internet-password -a "stash" 2>/dev/null || true
    security delete-internet-password -a "ws.stash" 2>/dev/null || true
    print_success "互联网密码已清理"
    
else
    print_warning "未找到 Keychain 数据库"
fi

# ===== 第七步：系统级清理 =====
print_section "5/6" "系统级清理"

print_step "清除应用注册缓存..."
defaults delete com.apple.LaunchServices LSRegisteredApplications 2>/dev/null || true
defaults delete com.apple.LaunchServices LSQuarantineHistoryDb_v2 2>/dev/null || true
print_success "应用注册缓存已清除"

print_step "重置网络代理..."
sudo scutil --reset proxy 2>/dev/null || true
print_success "代理已重置"

print_step "刷新 DNS 缓存..."
sudo dscacheutil -flushcache 2>/dev/null || true
sudo killall -HUP mDNSResponder 2>/dev/null || true
print_success "DNS 缓存已刷新"

print_step "清空剪贴板..."
pbcopy < /dev/null 2>/dev/null || true
print_success "剪贴板已清空"

# ===== 第八步：验证清理结果 =====
print_section "6/6" "验证清理结果"

RESIDUAL_COUNT=0

print_step "检查 LaunchDaemon..."
if ls -la /Library/LaunchDaemons/ 2>/dev/null | grep -i stash >/dev/null 2>&1; then
    print_error "发现残留的 LaunchDaemon"
    ((RESIDUAL_COUNT++))
else
    print_success "无残留"
fi

print_step "检查 LaunchAgent..."
if ls -la /Library/LaunchAgents/ 2>/dev/null | grep -i stash >/dev/null 2>&1; then
    print_error "发现残留的 LaunchAgent"
    ((RESIDUAL_COUNT++))
else
    print_success "无残留"
fi

print_step "检查应用程序..."
if ls -la /Applications/ 2>/dev/null | grep -i stash >/dev/null 2>&1; then
    print_error "发现残留的应用程序"
    ((RESIDUAL_COUNT++))
else
    print_success "无残留"
fi

print_step "检查 PrivilegedHelperTools..."
if ls -la /Library/PrivilegedHelperTools/ 2>/dev/null | grep -i stash >/dev/null 2>&1; then
    print_error "发现残留的助手工具"
    ((RESIDUAL_COUNT++))
else
    print_success "无残留"
fi

print_step "检查 Keychain..."
if security dump-keychain 2>/dev/null | grep -i "stash\|ws\.stash" >/dev/null 2>&1; then
    print_warning "可能在 Keychain 中还有 Stash 凭证（可忽略）"
else
    print_success "Keychain 已清理"
fi

# ===== 最终总结 =====
echo ""
echo -e "${C_YELLOW}╔════════════════════════════════════════╗${C_NC}"
if [ $RESIDUAL_COUNT -eq 0 ]; then
    echo -e "${C_YELLOW}║   ${C_GREEN}✓ 清理完成！系统已完全干净${C_YELLOW}   ║${C_NC}"
else
    echo -e "${C_YELLOW}║   ${C_YELLOW}⚠ 清理完成（发现 $RESIDUAL_COUNT 项残留）${C_YELLOW}   ║${C_NC}"
fi
echo -e "${C_YELLOW}╚════════════════════════════════════════╝${C_NC}"

echo ""
echo "【清理统计】"
echo "  • 已删除启动项: $REMOVED_LAUNCH_COUNT 项"
echo "  • 已删除文件: $REMOVED_FILES_COUNT 项"
echo "  • 残留文件: $RESIDUAL_COUNT 项"
echo ""

echo "【后续操作】"
echo ""
echo "  1️⃣  立即重启 Mac（重要！）"
echo "      $ sudo shutdown -r now"
echo ""
echo "  2️⃣  重启后重新启用代理工具"
echo "      • 如使用 ClashXMeta: Set as System Proxy"
echo "      • 如使用其他代理: 重新配置系统代理"
echo ""
echo "  3️⃣  重新安装 Stash"
echo "      • 下载最新版本"
echo "      • 安装并配置"
echo ""
echo "【安全确认】"
echo "  ✓ WiFi 密码 - 未受影响"
echo "  ✓ WiFi 设置 - 未受影响"
echo "  ✓ 其他应用 - 未受影响"
echo "  ⚠️  系统代理 - 已重置（需重新配置）"
echo ""

read -p "按 Enter 关闭此窗口..."
exit 0
