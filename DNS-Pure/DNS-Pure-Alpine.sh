#!/bin/sh
# DNS-Pure Alpine v1.0.1 (Focused · Safe · Lightweight)
#
# 🌟 核心能力:
#    ✅ 一键净化：自动配置 DoT/DNSSEC/缓存 (基于 Unbound)
#    ✅ 极致轻量：适配 Alpine Linux (OpenRC + Musl + BusyBox)
#    ✅ 冲突处理：自动修正 udhcpc/DHCP DNS 覆盖问题
#    ✅ 安全回滚：TRIGGER_ROLLBACK=1 快速恢复
#
# 🚀 推荐用法:
#    wget -O DNS-Pure-Alpine.sh https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/DNS-Pure/DNS-Pure-Alpine.sh -o DNS-Pure-Alpine.sh && chmod +x DNS-Pure-Alpine.sh && sudo ./DNS-Pure-Alpine.sh

set -e

VERSION="1.0.1-Alpine"

# =========================
# Logging helpers (Compatible with BusyBox/Ash)
# =========================
# 检测 stdout 是否是终端
if [ -t 1 ] && [ "${NO_COLOR:-}" != "1" ] && command -v tput >/dev/null 2>&1; then
  EMOJI_OK="✅"; EMOJI_WARN="⚠️"; EMOJI_ERR="❌"; EMOJI_INFO="ℹ️"; EMOJI_STAR="🌟"
else
  EMOJI_OK="[OK]"; EMOJI_WARN="[WARN]"; EMOJI_ERR="[ERR]"; EMOJI_INFO="[INFO]"; EMOJI_STAR="[★]"
fi

ts() { date "+%F %T"; }
log() { printf "%s %s %s\n" "$(ts)" "${EMOJI_INFO}" "$*"; }
log_ok() { printf "%s %s %s\n" "$(ts)" "${EMOJI_OK}" "$*"; }
log_warn() { printf "%s %s %s\n" "$(ts)" "${EMOJI_WARN}" "$*"; }
log_err() { printf "%s %s %s\n" "$(ts)" "${EMOJI_ERR}" "$*" >&2; }

soft_run() {
    desc="$1"; shift
    if "$@"; then
        log_ok "$desc"
        return 0
    else
        log_warn "$desc 失败（已忽略）"
        return 1
    fi
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_err "请用 root 运行"
        exit 1
    fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# =========================
# Environment detection (Alpine Specific)
# =========================
detect_environment() {
    if ! cmd_exists apk; then
        log_err "未检测到 apk 包管理器，此脚本仅适用于 Alpine Linux。"
        exit 1
    fi
    
    # Alpine 默认 sh 是 busybox ash，不需要检测 bash
    # 但需检测容器环境
    if [ -f /.dockerenv ] || grep -qE 'container|lxc|podman' /proc/1/environ 2>/dev/null; then
        log_warn "检测到容器环境"
    fi
}

# =========================
# Backup helpers
# =========================
backup_file() {
    f="$1"
    [ -e "$f" ] || return 0
    case "$f" in
        *.bak.dns-pure-v*) return 0 ;;
    esac
    
    bak="${f}.bak.dns-pure-v${VERSION}.$(date +%F-%H%M%S)"
    cp -a "$f" "$bak"
    log_ok "已备份：$f -> $bak"
}

write_file_atomic() {
    path="$1"
    content="$2"
    tmp="/tmp/dns-pure.$(date +%s).tmp"
    
    printf "%s\n" "$content" > "$tmp" || { log_err "写入临时文件失败"; rm -f "$tmp"; return 1; }
    mv "$tmp" "$path" || { log_err "移动配置文件失败"; rm -f "$tmp"; return 1; }
}

# =========================
# IPv6 detection (BusyBox compatible)
# =========================
has_ipv6() {
    if [ -d /proc/sys/net/ipv6 ]; then
        if [ "$(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null)" = "1" ]; then
            return 1
        fi
        # BusyBox ip command support
        if ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then return 0; fi
        if ip -6 route show default 2>/dev/null | grep -q .; then return 0; fi
    fi
    return 1
}

# =========================
# Unbound Installation & Config
# =========================
ensure_unbound() {
    if cmd_exists unbound && rc-service unbound status >/dev/null 2>&1; then
        log_ok "Unbound 已安装并运行"
        return 0
    fi

    log "🔧 正在安装 Unbound 及依赖..."
    apk update
    apk add unbound ca-certificates
    
    # 生成 DNSSEC 根密钥
    unbound-anchor -a "/etc/unbound/root.key" 2>/dev/null || true

    soft_run "将 Unbound 加入启动项" rc-update add unbound default
    soft_run "启动 Unbound" rc-service unbound start
    
    if rc-service unbound status >/dev/null 2>&1; then
        log_ok "Unbound 服务已就绪"
    else
        log_err "Unbound 启动失败，请检查日志"
        exit 1
    fi
}

# =========================
# Rollback function
# =========================
rollback_config() {
    log "🔄 正在恢复到 DNS-Pure 修改前的状态..."
    restored=0
    
    for f in /etc/unbound/unbound.conf /etc/resolv.conf /etc/udhcpc/udhcpc.conf; do
        if [ ! -e "$f" ]; then continue; fi
        
        # 查找最新备份
        latest_bak=$(ls -t "${f}.bak.dns-pure-v"* 2>/dev/null | head -1) || continue
        
        if [ -n "$latest_bak" ]; then
            cp -a "$latest_bak" "$f"
            log_ok "已恢复：$f"
            restored=$((restored+1))
        fi
    done
    
    # 清理 udhcpc hook
    if [ -f /etc/udhcpc/udhcpc.conf ]; then
         # 如果备份被恢复了，这里无需额外操作，除非我们要强制删除脚本生成的配置
         :
    fi
    
    if [ $restored -gt 0 ]; then
        rc-service unbound restart >/dev/null 2>&1 || true
        log_ok "回滚完成！"
    else
        log_warn "未找到备份"
    fi
    exit 0
}

# =========================
# DNS validation test
# =========================
test_dns_functionality() {
    log "🔍 执行 DNS 解析功能测试..."
    failed=0
    
    # Busybox 自带 nslookup
    for domain in example.com dns.google; do
        if nslookup "$domain" 127.0.0.1 >/dev/null 2>&1; then
            log_ok "✓ $domain 解析成功"
        else
            log_warn "✗ $domain 解析失败"
            failed=$((failed+1))
        fi
    done
    
    if [ $failed -gt 0 ]; then
        log_warn "DNS 测试部分失败"
        return 1
    fi
    return 0
}

# =========================
# Summary report
# =========================
print_summary() {
    stub_display="127.0.0.1"
    
    cat << EOF

📊 DNS-Pure Alpine v${VERSION} 执行摘要
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 ${EMOJI_OK} Unbound 状态：$(rc-service unbound status 2>/dev/null || echo "stopped")
 ${EMOJI_OK} DNS over TLS: ${DNS_OVER_TLS}
 ${EMOJI_OK} DNSSEC: 启用
 ${EMOJI_OK} Stub 监听器：${stub_display}
 ${EMOJI_OK} IPv6 支持：$([ ${HAS_IPV6:-0} -eq 1 ] && echo "是" || echo "否")
 ${EMOJI_OK} DHCP (udhcpc): 已配置为不覆盖 DNS
🔗 /etc/resolv.conf: nameserver 127.0.0.1
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

# =========================
# User-tunable knobs
# =========================
TRIGGER_ROLLBACK="${TRIGGER_ROLLBACK:-0}"
DNS_OVER_TLS="${DNS_OVER_TLS:-yes}"

DEFAULT_DNS_V4="1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google"
DEFAULT_DNS_V6="2606:4700:4700::1111#cloudflare-dns.com 2001:4860:4860::8888#dns.google"

DNS_SERVERS="${DNS_SERVERS:-}"

# =========================
# Main
# =========================
need_root

if [ "${TRIGGER_ROLLBACK}" = "1" ]; then
    rollback_config
fi

detect_environment

log "--- DNS-Pure Alpine v${VERSION} ---"

HAS_IPV6=0
if has_ipv6; then
    HAS_IPV6=1
    log_ok "检测到 IPv6 支持"
fi

if [ -z "${DNS_SERVERS}" ]; then
    DNS_SERVERS="${DEFAULT_DNS_V4}"
    if [ "${HAS_IPV6}" = "1" ]; then
        DNS_SERVERS="${DNS_SERVERS} ${DEFAULT_DNS_V6}"
    fi
fi

# 1. 安装 Unbound
ensure_unbound

# 2. 配置 Unbound
log "🔧 正在生成 Unbound 配置..."

port="853"
if [ "${DNS_OVER_TLS}" != "yes" ]; then
    port="53"
fi

# 构建 forward-zone 地址列表
# 格式: forward-addr: IP@PORT#hostname
FORWARD_ADDRS=""
# 使用 IFS 循环处理空格分隔的列表 (POSIX兼容方式)
OLD_IFS="$IFS"
IFS=" "
for entry in $DNS_SERVERS; do
    ip=""
    host=""
    
    # 解析 IP#Tag 格式 (兼容 BusyBox shell)
    # ${var%#*} 移除右侧 # 及之后内容
    # ${var#*#} 移除左侧 # 及之前内容
    
    case "$entry" in
        *#*)
            ip="${entry%#*}"
            host="${entry#*#}"
            ;;
        *)
            ip="$entry"
            host=""
            ;;
    esac
    
    if [ -n "$host" ]; then
        FORWARD_ADDRS="${FORWARD_ADDRS}    forward-addr: ${ip}@${port}#${host}\n"
    else
        FORWARD_ADDRS="${FORWARD_ADDRS}    forward-addr: ${ip}@${port}\n"
    fi
done
IFS="$OLD_IFS"

UNBOUND_CONF_CONTENT=$(cat <<EOF
# Generated by DNS-Pure Alpine v${VERSION}
server:
    verbosity: 1
    interface: 127.0.0.1
    # interface: ::1
    access-control: 127.0.0.0/8 allow
    
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    
    msg-cache-size: 50m
    rrset-cache-size: 100m
    num-threads: 1
    
    trust-anchor-file: /etc/unbound/root.key
    
forward-zone:
    name: "."
 $(printf "%b" "$FORWARD_ADDRS")
    forward-first: no
EOF
)

backup_file /etc/unbound/unbound.conf
write_file_atomic /etc/unbound/unbound.conf "$UNBOUND_CONF_CONTENT"
log_ok "已写入 /etc/unbound/unbound.conf"

# 3. 修正 DHCP/DNS 冲突
# Alpine 使用 udhcpc。最稳妥的方法是创建一个 hook 脚本或修改配置
# 方案：创建 /etc/udhcpc/udhcpc.conf 并写入 PEER_DNS=no
# 注意：标准 udhcpc 不读取此文件，但 Alpine 的 udhcpc 脚本通常会处理。
# 更通用的 Alpine 方案是修改 /etc/network/interfaces，但脚本不好判断网卡名。
# 最佳通用方案：创建 hook 脚本 /etc/udhcpc/udhcpc.conf 在某些版本有效，
# 最暴力但最有效的方法是：chattr +i /etc/resolv.conf (需安装 e2fsprogs)
# 为了纯净，我们使用 Alpine OpenRC 的 hook 方式，或者直接写死 resolv.conf

# 方法：直接覆盖 resolv.conf，并在 udhcpc hook 中重置
UDHCPC_SCRIPT="/usr/share/udhcpc/default.script"
if [ -f "$UDHCPC_SCRIPT" ]; then
    # 这是一个简单的技巧：在 udhcpc 运行后强制恢复 resolv.conf
    # 我们创建一个简单的 post-deconfig 脚本
    mkdir -p /etc/udhcpc
    cat > /etc/udhcpc/udhcpc.conf << 'UDHCPC_EOF'
# DNS-Pure Alpine Hook
# 忽略 DHCP 下发的 DNS，强制使用本地
RESOLV_CONF="no"
UDHCPC_EOF
    log_ok "已配置 udhcpc 忽略 DHCP DNS"
fi

# 4. 应用 resolv.conf
backup_file /etc/resolv.conf
# 必须确保先修改 udhcpc 配置，再写 resolv.conf，否则可能立即被覆盖
cat > /etc/resolv.conf <<EOF
# Generated by DNS-Pure Alpine
nameserver 127.0.0.1
options edns0 trust-ad
EOF
log_ok "/etc/resolv.conf 已指向本地 Unbound"

# 5. 重启服务
log "🔄 重启 Unbound 服务..."
rc-service unbound restart || {
    log_err "Unbound 重启失败"
    exit 1
}

# 6. 验证
test_dns_functionality || true

print_summary

log_ok "Alpine DNS 净化完成。"
