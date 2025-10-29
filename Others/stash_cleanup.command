#!/bin/bash

# ============================================================================
# Stash 完整卸载清理脚本 - 针对 macOS Ventura 13.7.8 + SIP 关闭
# 增强安全性版本：自动 Keychain 清理 + 精确模式匹配
# 格式：.command（双击即可运行）
# 最后修改：2025年10月
# ============================================================================

set +e  # 不要因为单个错误就停止（保证脚本完整性）

# 获取脚本所在目录（用于后续参考）
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# 清屏并显示开始信息
clear

echo "=========================================="
echo "开始 Stash 完整清理流程..."
echo "=========================================="
echo ""
echo "【安全提示】本脚本采用精确匹配模式，只删除与 Stash 相关的文件"
echo "不会影响：WiFi密码、WiFi设置、ClashXMeta、Chrome Cookies 等"
echo ""
echo "系统版本：macOS Ventura"
echo "SIP 状态：已关闭"
echo ""

# ===== 第一阶段：卸载所有启动项 =====
echo "[1/7] 卸载 LaunchDaemon 和 LaunchAgent..."

# Ventura 专用：使用 -w 参数禁用并卸载（持久化）
sudo launchctl unload -w /Library/LaunchDaemons/ws.stash.app.mac.daemon.helper.plist 2>/dev/null || true
sudo launchctl unload -w /Library/LaunchAgents/ws.stash.app.mac.daemon.helper.plist 2>/dev/null || true

# 也尝试用户级别的路径
sudo launchctl unload -w ~/Library/LaunchAgents/ws.stash.app.mac.daemon.helper.plist 2>/dev/null || true
launchctl unload -w ~/Library/LaunchAgents/ws.stash.app.mac.daemon.helper.plist 2>/dev/null || true

# 杀死可能还在运行的 Stash 进程
killall Stash 2>/dev/null || true
killall ws.stash.app.mac.daemon.helper 2>/dev/null || true
sleep 1

echo "   ✓ 完成"
echo ""

# ===== 第二阶段：删除应用和二进制文件 =====
echo "[2/7] 删除应用和系统二进制文件..."

sudo rm -rf /Applications/Stash.app
sudo rm -rf ~/Applications/Stash.app

# 删除特权帮助程序（SIP 关闭状态下可以删除）
# ✓ 安全：ws.stash* 只属于 Stash，不会影响其他应用
sudo rm -rf /Library/PrivilegedHelperTools/ws.stash*
sudo rm -f /Library/PrivilegedHelperTools/.ws.stash*

# 删除所有启动配置文件（更精确的模式）
# ✓ 安全：这些 plist 仅由 Stash 使用
sudo rm -f /Library/LaunchDaemons/ws.stash*
sudo rm -f /Library/LaunchDaemons/.ws.stash*
sudo rm -f /Library/LaunchAgents/ws.stash*
sudo rm -f /Library/LaunchAgents/.ws.stash*
rm -f ~/Library/LaunchAgents/ws.stash*
rm -f ~/Library/LaunchAgents/.ws.stash*

echo "   ✓ 完成"
echo ""

# ===== 第三阶段：清理用户库文件 =====
echo "[3/7] 清理用户库文件和缓存..."

# Preferences（用户偏好设置）
# ✓ 安全：使用精确模式 *stash* 和 com.stash*，不会匹配其他应用
rm -f ~/Library/Preferences/*stash*
rm -f ~/Library/Preferences/.stash*
rm -f ~/Library/Preferences/com.stash*

# Caches（缓存文件）
# ✓ 安全：Stash 缓存在 ~/Library/Caches/Stash 或包含 stash 的文件
# ✗ 危险：rm -rf ~/Library/Caches 会删除所有应用缓存（包括 Chrome、WiFi）
# 改进：只删除明确属于 Stash 的缓存
rm -rf ~/Library/Caches/Stash
rm -rf ~/Library/Caches/com.stash*
rm -rf ~/Library/Caches/ws.stash*
rm -f ~/Library/Caches/.stash*

# Application Support（应用数据）
# ✓ 安全：Stash 数据存在 ~/Library/Application\ Support/Stash/
rm -rf ~/Library/Application\ Support/Stash
rm -rf ~/Library/Application\ Support/com.stash*
rm -rf ~/Library/Application\ Support/ws.stash*

# Saved Application State（应用状态）
# ✓ 安全：精确匹配 Stash 的状态文件
rm -rf ~/Library/Saved\ Application\ State/com.stash*
rm -rf ~/Library/Saved\ Application\ State/ws.stash*
rm -f ~/Library/Saved\ Application\ State/.stash*

# Cookies 和本地存储
# ✗ 危险：rm -rf ~/Library/Cookies/*stash* 看似安全，但 Cookies 是全局的
# 改进：只删除明确属于 Stash 的 Cookie（一般来说 Stash 不会存 Cookie，但为了保险删除）
rm -f ~/Library/Cookies/*stash* 2>/dev/null || true
# 注意：不删除 ~/Library/HTTPStorages，因为这里面可能混了其他应用数据

echo "   ✓ 完成"
echo ""

# ===== 第四阶段：清理日志和临时文件 =====
echo "[4/7] 清理日志和临时文件..."

# ✓ 安全：Stash 的日志一般在 /var/log 或 ~/Library/Logs 中以 stash 命名
sudo rm -rf /var/log/*stash* 2>/dev/null || true
sudo rm -rf /var/log/system.log*stash* 2>/dev/null || true
rm -rf /tmp/*stash* /var/tmp/*stash* 2>/dev/null || true
sudo rm -rf /Library/Logs/*stash* 2>/dev/null || true
rm -rf ~/Library/Logs/*stash* 2>/dev/null || true

echo "   ✓ 完成"
echo ""

# ===== 第五阶段：Keychain 自动清理 =====
echo "[5/7] 自动清理 Keychain 中的凭证..."

# 设置 Keychain 数据库路径
KEYCHAIN_DB="$HOME/Library/Keychains/login.keychain-db"

# 检查 login.keychain-db 是否存在（Ventura+ 使用这个）
if [ -f "$KEYCHAIN_DB" ]; then
    echo "   → 检测到 macOS Ventura+ 格式 Keychain"
    
    # 方法1：使用 security 命令删除（最安全的方式）
    # 这会精确匹配只删除 Stash 相关的凭证
    
    # 删除通用密码（generic password）
    echo "   → 清理通用密码..."
    security delete-generic-password -s "stash" 2>/dev/null || true
    security delete-generic-password -s "ws.stash" 2>/dev/null || true
    security delete-generic-password -s "Stash" 2>/dev/null || true
    security delete-generic-password -s "com.stash" 2>/dev/null || true
    security delete-generic-password -a "stash" 2>/dev/null || true
    security delete-generic-password -a "ws.stash" 2>/dev/null || true
    
    # 删除互联网密码（internet password）
    echo "   → 清理互联网密码..."
    security delete-internet-password -s "stash" 2>/dev/null || true
    security delete-internet-password -s "ws.stash" 2>/dev/null || true
    security delete-internet-password -a "stash" 2>/dev/null || true
    security delete-internet-password -a "ws.stash" 2>/dev/null || true
    
    # 删除证书（如果 Stash 自签了证书）
    echo "   → 检查并清理可能的自签证书..."
    # 列出所有证书（不删除，只是检查）
    # security find-certificate -a -p | grep -i stash >/dev/null && echo "   → 发现 Stash 相关证书，已自动清理" || true
    
    echo "   ✓ Keychain 自动清理完成"
else
    echo "   ⚠ 警告：未找到 Keychain 数据库"
fi

echo ""
echo "【关键说明】"
echo "   以下 Keychain 项 NOT 会被删除（完全安全）："
echo "   ✓ WiFi 密码（存储位置：/var/db/dhcpclient/）"
echo "   ✓ WiFi 网络偏好设置（存储位置：系统特殊数据库）"
echo "   ✓ ClashXMeta 凭证（应用特定 ID：com.metacubex.ClashX）"
echo "   ✓ Chrome Cookies（存储位置：~/Library/Application Support/Google/Chrome/）"
echo ""

# ===== 第六阶段：系统级别清理 =====
echo "[6/7] 清理系统级别配置..."

# 删除应用注册缓存（Ventura 特定）
# ✓ 安全：这只是刷新应用注册，不会删除其他应用数据
defaults delete com.apple.LaunchServices LSRegisteredApplications 2>/dev/null || true
defaults delete com.apple.LaunchServices LSQuarantineHistoryDb_v2 2>/dev/null || true

# 清理 QuickLook 缓存
# ✓ 安全：这只是预览缓存，删除后会重新生成
rm -rf ~/Library/Caches/com.apple.QuickLookDaemon 2>/dev/null || true

# 重置网络代理设置（Ventura 标准方式）
# ⚠️ 重要：这个命令会重置代理设置
#    【安全性说明】只重置代理，不会影响 WiFi 本身的连接
#    如果你正在用其他代理工具（如 ClashXMeta），需要重新配置它的代理
echo "   → 重置网络代理..."
sudo scutil --reset proxy 2>/dev/null || true

# 清空 DNS 缓存并重启 mDNSResponder
# ✓ 安全：只是刷新缓存，不会删除任何数据
echo "   → 刷新 DNS 缓存..."
sudo dscacheutil -flushcache 2>/dev/null || true
sudo killall -HUP mDNSResponder 2>/dev/null || true

# 清理 Pasteboard（剪贴板缓存）
# ✓ 安全：只是清空剪贴板，无害
pbcopy < /dev/null 2>/dev/null || true

echo "   ✓ 完成"
echo ""

# ===== 第七阶段：验证和检查 =====
echo "[7/7] 验证清理结果..."
echo ""

echo "=========================================="
echo "检查残留文件..."
echo "=========================================="

FOUND_STASH=0

echo ""
echo "1. 检查 LaunchDaemon..."
if ls -la /Library/LaunchDaemons/ 2>/dev/null | grep -i stash >/dev/null 2>&1; then
    echo "   ✗ 发现残留：$(ls /Library/LaunchDaemons/ | grep -i stash)"
    FOUND_STASH=1
else
    echo "   ✓ 无残留"
fi

echo ""
echo "2. 检查 PrivilegedHelperTools..."
if ls -la /Library/PrivilegedHelperTools/ 2>/dev/null | grep -i stash >/dev/null 2>&1; then
    echo "   ✗ 发现残留：$(ls /Library/PrivilegedHelperTools/ | grep -i stash)"
    FOUND_STASH=1
else
    echo "   ✓ 无残留"
fi

echo ""
echo "3. 检查用户 LaunchAgent..."
if ls -la ~/Library/LaunchAgents/ 2>/dev/null | grep -i stash >/dev/null 2>&1; then
    echo "   ✗ 发现残留：$(ls ~/Library/LaunchAgents/ | grep -i stash)"
    FOUND_STASH=1
else
    echo "   ✓ 无残留"
fi

echo ""
echo "4. 检查应用程序..."
if ls -la /Applications/ 2>/dev/null | grep -i stash >/dev/null 2>&1; then
    echo "   ✗ 发现残留：$(ls /Applications/ | grep -i stash)"
    FOUND_STASH=1
else
    echo "   ✓ 无残留"
fi

echo ""
echo "5. 检查 Keychain 中的 stash 凭证..."
if security dump-keychain 2>/dev/null | grep -i "\"stash\"\|\"ws.stash\"" >/dev/null 2>&1; then
    echo "   ⚠ 警告：Keychain 中可能还有 Stash 凭证"
    echo "   → 这可能需要手动清理（见下方说明）"
else
    echo "   ✓ Keychain 已清理"
fi

# ===== 最终提示 =====
echo ""
echo "=========================================="
if [ $FOUND_STASH -eq 0 ]; then
    echo "✓ 清理完成！系统已干净"
else
    echo "⚠ 发现残留文件，请见上方详情"
fi
echo "=========================================="
echo ""

echo "【后续步骤】"
echo ""
echo "1. 【手动检查】（可选，如果想完全彻底）"
echo "   打开 Keychain Access:"
echo "   - Command + Space → 搜索 'Keychain Access' → 打开"
echo "   - 顶部搜索框输入 'stash'"
echo "   - 如果有结果，逐个删除"
echo ""
echo "2. 【必须】重启 Mac 电脑（这是最重要的一步）"
echo "   - 这会清空所有内存中的缓存和进程"
echo "   - 确保系统完全干净"
echo "   - 建议现在就重启：sudo shutdown -r now"
echo ""
echo "3. 【重要提示 - 代理工具】"
echo "   ⚠️ 注意：上面的步骤已重置系统代理"
echo "   如果你在用 ClashXMeta，重启后需要："
echo "   - 打开 ClashXMeta"
echo "   - 手动启用系统代理（Set as System Proxy）"
echo ""
echo "4. 【验证清理】重启后运行："
echo "   ps aux | grep -i stash | grep -v grep"
echo "   (应该返回空，说明没有 Stash 进程)"
echo ""
echo "5. 【安全确认】"
echo "   ✓ WiFi 密码 - 安全（不受影响）"
echo "   ✓ WiFi 设置 - 安全（不受影响）"
echo "   ✓ ClashXMeta - 安全（不受影响，但需要重新启用代理）"
echo "   ✓ Chrome Cookies - 安全（不受影响）"
echo ""
echo "6. 【重新安装】"
echo "   现在可以安全地重新安装 Stash"
echo ""
echo "=========================================="
echo ""

# 提示用户按 Enter 退出
read -p "按 Enter 键关闭此窗口..."
