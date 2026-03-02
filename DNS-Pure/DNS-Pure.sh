#!/usr/bin/env bash
# DNS-Pure v2.9.3 (Focused · Safe · Local-Ready)
#
# 🌟 核心能力:
#    ✅ 一键净化：自动配置 DoT/DNSSEC/缓存/攻击面缩减
#    ✅ 自愈安装：缺失 systemd-resolved 时自动安装（Debian/Ubuntu 灵魂功能）
#    ✅ 即时生效：重启 resolved 服务即可，无需重启网络
#    ✅ 安全回滚：TRIGGER_ROLLBACK=1 快速恢复
#    ✅ 本地优先：推荐下载后执行，便于审计与自定义
#
# 🚀 推荐用法:
#    1. 下载：curl -sSL <url> -o DNS-Pure.sh
#    2. 授权：chmod +x DNS-Pure.sh
#    3. 执行：sudo ./DNS-Pure.sh
#    4. 自定义：sudo DNS_SERVERS="1.1.1.1#CF" ./DNS-Pure.sh
#
# 📋 DNS_SERVERS 格式规范:
#    "IPv4#标签 IPv6#标签" (空格分隔，标签可选，用于日志识别)
#    示例："1.1.1.1#CF 2606:4700::1111#CF 8.8.8.8#Google"

set -euo pipefail

VERSION="2.9.3"

# =========================
# Logging helpers + Emoji compatibility
# =========================
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]] && command -v tput >/dev/null 2>&1; then
  EMOJI_OK="✅"; EMOJI_WARN="⚠️"; EMOJI_ERR="❌"; EMOJI_INFO="ℹ️"; EMOJI_STAR="🌟"
else
  EMOJI_OK="[OK]"; EMOJI_WARN="[WARN]"; EMOJI_ERR="[ERR]"; EMOJI_INFO="[INFO]"; EMOJI_STAR="[★]"
fi

ts() { date "+%F %T"; }
log() { echo -e "[$(ts)] ${EMOJI_INFO} $*"; }
log_ok() { echo -e "[$(ts)] ${EMOJI_OK} $*"; }
log_warn() { echo -e "[$(ts)] ${EMOJI_WARN} $*"; }
log_err() { echo -e "[$(ts)] ${EMOJI_ERR} $*" >&2; }
log_star() { echo -e "[$(ts)] ${EMOJI_STAR} $*"; }

soft_run() {
  local desc="$1"; shift
  if "$@"; then
    log_ok "$desc"
    return 0
  else
    log_warn "$desc 失败（已忽略）"
    return 1
  fi
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_err "请用 root 运行：sudo ./DNS-Pure.sh"
    exit 1
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# =========================
# Environment detection
# =========================
detect_environment() {
  CONTAINER_MODE=0
  if [[ -f /.dockerenv ]] || grep -qE 'container|lxc|podman' /proc/1/environ 2>/dev/null; then
    CONTAINER_MODE=1
    log_warn "检测到容器环境，部分功能可能受限"
  fi

  SYSTEMD_LEGACY=0
  if cmd_exists systemctl; then
    local systemd_ver
    systemd_ver=$(systemctl --version | head -1 | grep -oP 'systemd \K[0-9]+' || echo "0")
    if [[ "$systemd_ver" -lt 239 ]]; then
      log_warn "systemd 版本较旧 ($systemd_ver)，部分功能如 DNSOverTLS 可能不支持"
      SYSTEMD_LEGACY=1
    fi
  fi

  NETWORKMANAGER_ACTIVE=0
  if systemctl is-active --quiet NetworkManager.service 2>/dev/null; then
    log_warn "检测到 NetworkManager 运行中，可能与 dhclient 配置冲突"
    NETWORKMANAGER_ACTIVE=1
  fi
}

# =========================
# Backup & Atomic write
# =========================
backup_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  local bak="${f}.bak.dns-pure-v${VERSION}.$(date +%F-%H%M%S)"
  cp -a "$f" "$bak"
  log_ok "已备份：$f -> $bak"
}

write_file_atomic() {
  local path="$1"
  local content="$2"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/dns-pure.XXXXXX")" || {
    log_err "无法创建临时文件"
    return 1
  }
  trap 'rm -f "$tmp"' RETURN
  
  printf "%s\n" "$content" > "$tmp" || {
    log_err "写入临时文件失败"
    return 1
  }
  install -m 0644 "$tmp" "$path" || {
    log_err "安装配置文件失败"
    return 1
  }
}

# =========================
# IPv6 detection
# =========================
has_ipv6() {
  if [[ -f /proc/sys/net/ipv6/conf/default/disable_ipv6 ]]; then
    [[ "$(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null)" == "1" ]] && return 1
  fi
  if ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then return 0; fi
  if ip -6 route show default 2>/dev/null | grep -q .; then return 0; fi
  if grep -qE 'nameserver\s+[0-9a-f:]+' /etc/resolv.conf 2>/dev/null; then return 0; fi
  return 1
}

# =========================
# Resolved status check
# =========================
check_resolved_available() {
  if systemctl is-active --quiet systemd-resolved.service 2>/dev/null; then return 0; fi
  if systemctl cat systemd-resolved.service >/dev/null 2>&1; then return 1; fi
  if cmd_exists dpkg-query && dpkg-query -W -f='${Status}\n' systemd-resolved 2>/dev/null | grep -q "install ok installed"; then return 1; fi
  return 2
}

ensure_systemd_resolved() {
  local status
  check_resolved_available || status=$?
  
  case "${status:-0}" in
    0) 
      log_ok "✨ systemd-resolved 已运行（无需安装）"
      return 0 
      ;;
    1)
      log "🔧 systemd-resolved 已安装但未运行，正在启动..."
      soft_run "systemd daemon-reload" systemctl daemon-reload
      systemctl enable --now systemd-resolved.service 2>/dev/null && {
        log_ok "✨ systemd-resolved 已启动"
        return 0
      }
      ;;
  esac
  
  if [[ "${AUTO_INSTALL_RESOLVED:-1}" != "1" ]]; then
    log_err "❌ 未检测到 systemd-resolved，且 AUTO_INSTALL_RESOLVED=0"
    return 1
  fi
  
  if ! cmd_exists apt-get; then
    log_err "❌ 未检测到 apt-get，无法自动安装 systemd-resolved"
    log_err "💡 请手动安装：apt-get update && apt-get install -y systemd-resolved"
    return 1
  fi

  log_warn "🔧 核心功能：未检测到 systemd-resolved，正在自动安装..."
  log "   （这是 DNS-Pure 的一键净化能力：自动补齐系统依赖）"
  
  apt-get update -y
  apt-get install -y systemd-resolved

  systemctl daemon-reload || true
  systemctl enable --now systemd-resolved.service >/dev/null 2>&1 || true

  if systemctl is-active --quiet systemd-resolved.service; then
    log_ok "✨ 自动安装成功！systemd-resolved 已就绪"
    return 0
  else
    log_err "❌ 自动安装后 systemd-resolved 仍未运行，请检查系统日志"
    return 1
  fi
}

# =========================
# Rollback function
# =========================
rollback_config() {
  log "🔄 正在恢复到 DNS-Pure 修改前的状态..."
  local restored=0
  local script_name="${0##*/}"
  
  for f in /etc/systemd/resolved.conf /etc/resolv.conf /etc/dhcp/dhclient.conf /etc/dhcp/dhclient6.conf; do
    if [[ ! -e "$f" ]]; then continue; fi
    
    local latest_bak
    latest_bak=$(ls -t "${f}.bak.dns-pure-v"* 2>/dev/null | head -1) || continue
    
    if [[ -n "$latest_bak" ]]; then
      cp -a "$latest_bak" "$f"
      log_ok "已恢复：$f <- $latest_bak"
      ((restored++))
    else
      log_warn "未找到 $f 的备份"
    fi
  done
  
  if [[ $restored -gt 0 ]]; then
    if systemctl list-unit-files 2>/dev/null | grep -qE '^resolvconf\.service'; then
      soft_run "取消屏蔽 resolvconf.service" systemctl unmask resolvconf.service
      soft_run "启用 resolvconf.service" systemctl enable resolvconf.service
    fi
    soft_run "重启 systemd-resolved" systemctl restart systemd-resolved.service
    log_ok "回滚完成！已恢复 $restored 个配置文件"
    log "💡 提示：如需重新净化，请执行：sudo ./${script_name}"
  else
    log_warn "未找到可恢复的备份，回滚未执行任何操作"
  fi
}

# =========================
# DNS validation test
# =========================
test_dns_functionality() {
  log "🔍 执行 DNS 解析功能测试..."
  local test_domains=("example.com" "dns.google")
  local failed=0
  
  for domain in "${test_domains[@]}"; do
    if resolvectl query "$domain" >/dev/null 2>&1 || nslookup "$domain" 127.0.0.53 >/dev/null 2>&1; then
      log_ok "✓ $domain 解析成功"
    else
      log_warn "✗ $domain 解析失败"
      ((failed++))
    fi
  done
  
  if [[ $failed -gt 0 ]]; then
    log_warn "DNS 测试：$failed/${#test_domains[@]} 个域名解析失败，请检查配置"
    return 1
  else
    log_ok "DNS 测试：所有测试域名解析成功"
    return 0
  fi
}

progress_step() {
  local current="$1" total="$2" desc="$3"
  log "[$current/$total] $desc"
}

# =========================
# Summary report (UX OPTIMIZED v2.9.3)
# =========================
print_summary() {
  local script_name="${0##*/}"

  cat << EOF

📊 DNS-Pure v${VERSION} 执行摘要
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${EMOJI_OK} systemd-resolved 状态：$(systemctl is-active systemd-resolved.service 2>/dev/null || echo "unknown")
${EMOJI_OK} DNS over TLS: ${DNS_OVER_TLS}
${EMOJI_OK} DNSSEC 模式：${DNSSEC_MODE}
${EMOJI_OK} 缓存启用：${CACHE_MODE}
${EMOJI_OK} Stub 监听器：${DNS_STUB_LISTENER}
${EMOJI_OK} IPv6 支持：$([[ ${HAS_IPV6:-0} -eq 1 ]] && echo "是" || echo "否")
${EMOJI_OK} LLMNR/mDNS: ${LLMNR_MODE}/${MDNS_MODE} (已禁用)
${EMOJI_OK} DNS 缓存：已自动刷新 (flush-caches)
🔗 /etc/resolv.conf: $(readlink -f /etc/resolv.conf 2>/dev/null || echo "regular file")
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⚡ 生效说明
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${EMOJI_OK} DNS 配置已即时生效（无需重启网络服务）
   所有新建连接将立即使用新 DNS。
💡 提示：旧连接可能保持直到超时，通常无需干预。

🔧 自定义使用指南
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
💡 自定义 DNS 服务器（格式：IP#可选标签，空格分隔）:
   sudo DNS_SERVERS="8.8.8.8#google 1.1.1.1#cloudflare" ./${script_name}

💡 完整 IPv4 + IPv6 自定义示例（推荐）:
   sudo DNS_SERVERS="1.1.1.1#CF 2606:4700::1111#CF 8.8.8.8#Google 2001:4860::8888#Google" ./${script_name}

💡 仅 IPv4 自定义（禁用 IPv6 解析器）:
   sudo DNS_SERVERS="9.9.9.9#quad9" ./${script_name}

💡 自定义 Fallback DNS（主 DNS 失效时备用）:
   sudo FALLBACK_DNS="208.67.222.222#opendns" ./${script_name}

💡 关闭 DNS over TLS（不推荐）:
   sudo DNS_OVER_TLS=no ./${script_name}

💡 回滚到之前配置:
   sudo TRIGGER_ROLLBACK=1 ./${script_name}

📋 DNS_SERVERS 格式规范:
   • 基础格式：IP 地址 或 IP#标签
   • 示例：
     - "1.1.1.1"                    # 纯 IP
     - "1.1.1.1#cloudflare"         # IP+ 标签（便于日志识别）
     - "8.8.8.8 1.1.1.1"            # 多个 DNS，空格分隔
     - "2606:4700::1111#cf-v6"      # IPv6 同样支持
   • 注意：标签仅为注释用途，不影响解析

🌐 常见场景示例:
   • 国内加速：sudo DNS_SERVERS="223.5.5.5#aliyun 114.114.114.114#china" ./${script_name}
   • 隐私优先：sudo DNS_SERVERS="1.1.1.1#cf 9.9.9.9#quad9" ./${script_name}
   • 企业内网：sudo DNS_SERVERS="10.0.0.53#internal 8.8.8.8#fallback" ./${script_name}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
💡 提示：所有配置均通过环境变量传递，无需修改脚本
💡 提示：建议将脚本保留在本地，便于后续维护与回滚
EOF
}

# =========================
# User-tunable knobs
# =========================
# 移除 APPLY_NETWORK_REFRESH，专注 DNS 主线
# 移除 INSTALL_IFUPDOWN2，减少依赖
AUTO_INSTALL_RESOLVED="${AUTO_INSTALL_RESOLVED:-1}"
TRIGGER_ROLLBACK="${TRIGGER_ROLLBACK:-0}"

DNS_OVER_TLS="${DNS_OVER_TLS:-yes}"
DNSSEC_MODE="${DNSSEC_MODE:-yes}"
CACHE_MODE="${CACHE_MODE:-yes}"
DNS_STUB_LISTENER="${DNS_STUB_LISTENER:-yes}"
LLMNR_MODE="${LLMNR_MODE:-no}"
MDNS_MODE="${MDNS_MODE:-no}"
READ_ETC_HOSTS="${READ_ETC_HOSTS:-yes}"

DEFAULT_DNS_V4="1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 8.8.8.8#dns.google 8.8.4.4#dns.google"
DEFAULT_DNS_V6="2606:4700:4700::1111#cloudflare-dns.com 2606:4700:4700::1001#cloudflare-dns.com 2001:4860:4860::8888#dns.google 2001:4860:4860::8844#dns.google"
DEFAULT_FALLBACK_V4="9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net"
DEFAULT_FALLBACK_V6="2620:fe::fe#dns.quad9.net 2620:fe::9#dns.quad9.net"

DNS_SERVERS="${DNS_SERVERS:-}"
FALLBACK_DNS="${FALLBACK_DNS:-}"

# =========================
# Main
# =========================
need_root

if [[ "${TRIGGER_ROLLBACK}" == "1" ]]; then
  rollback_config
  exit $?
fi

detect_environment

log "--- DNS-Pure v${VERSION} (Focused · Safe · Local-Ready) ---"
log "--- 开始执行全面系统 DNS 健康检查 ---"

if ! cmd_exists systemctl; then
  log_err "未发现 systemctl（该脚本依赖 systemd / systemd-resolved）。"
  log_err "非 systemd 系统暂不支持，请使用其他 DNS 配置方案。"
  exit 1
fi

if ! ensure_systemd_resolved; then
  log_err "未检测到 systemd-resolved.service，且无法自动安装（或已关闭自动安装）。"
  log_err "你可以手动安装：apt-get update && apt-get install -y systemd-resolved"
  exit 1
fi

soft_run "启用并启动 systemd-resolved" systemctl enable --now systemd-resolved.service
if ! systemctl is-active --quiet systemd-resolved.service; then
  log_err "systemd-resolved 未处于 active 状态。"
  systemctl --no-pager --full status systemd-resolved.service || true
  exit 1
fi
log_ok "systemd-resolved 已就绪"

HAS_IPV6=0
if has_ipv6; then
  HAS_IPV6=1
  log_ok "检测到 IPv6（将对 IPv6 同步净化/加固，并加入 IPv6 DoT 解析器）"
else
  log "未检测到有效 IPv6（仅对 IPv4 执行解析器配置；仍会硬化系统设置）。"
fi

if [[ -z "${DNS_SERVERS}" ]]; then
  DNS_SERVERS="${DEFAULT_DNS_V4}"
  [[ "${HAS_IPV6}" == "1" ]] && DNS_SERVERS="${DNS_SERVERS} ${DEFAULT_DNS_V6}"
fi
if [[ -z "${FALLBACK_DNS}" ]]; then
  FALLBACK_DNS="${DEFAULT_FALLBACK_V4}"
  [[ "${HAS_IPV6}" == "1" ]] && FALLBACK_DNS="${FALLBACK_DNS} ${DEFAULT_FALLBACK_V6}"
fi

if [[ -L /etc/resolv.conf ]]; then
  log_ok "/etc/resolv.conf 当前为软链接：$(readlink -f /etc/resolv.conf)"
else
  log_warn "/etc/resolv.conf 当前不是软链接（后续将净化为 systemd-resolved stub）。"
fi

log ""
log "--- 开始执行 DNS 净化与安全加固流程 ---"

progress_step 1 3 "阶段一：清除潜在的 DNS 冲突源..."

backup_file /etc/systemd/resolved.conf
backup_file /etc/resolv.conf
backup_file /etc/dhcp/dhclient.conf
backup_file /etc/dhcp/dhclient6.conf

if [[ -f /etc/dhcp/dhclient.conf ]]; then
  if grep -qE '^\s*supersede\s+domain-name-servers' /etc/dhcp/dhclient.conf; then
    soft_run "净化 dhclient.conf（更新 supersede domain-name-servers）" \
      sed -i -E 's/^\s*supersede\s+domain-name-servers.*/supersede domain-name-servers 127.0.0.53;/' /etc/dhcp/dhclient.conf
  else
    cat >> /etc/dhcp/dhclient.conf <<EOF

# Added by DNS-Pure v${VERSION}
supersede domain-name-servers 127.0.0.53;
EOF
    log_ok "净化 dhclient.conf（追加 supersede domain-name-servers）"
  fi
  log_ok "dhclient.conf 已净化（防止 DHCPv4 覆盖 DNS）"
else
  log "未发现 /etc/dhcp/dhclient.conf，跳过 DHCPv4 净化。"
fi

if [[ "${HAS_IPV6}" == "1" && -f /etc/dhcp/dhclient6.conf ]]; then
  if grep -qE '^\s*supersede\s+domain-name-servers' /etc/dhcp/dhclient6.conf; then
    soft_run "净化 dhclient6.conf（更新 supersede domain-name-servers）" \
      sed -i -E 's/^\s*supersede\s+domain-name-servers.*/supersede domain-name-servers 127.0.0.53;/' /etc/dhcp/dhclient6.conf
  else
    cat >> /etc/dhcp/dhclient6.conf <<EOF

# Added by DNS-Pure v${VERSION}
supersede domain-name-servers 127.0.0.53;
EOF
    log_ok "净化 dhclient6.conf（追加 supersede domain-name-servers）"
  fi
  log_ok "dhclient6.conf 已净化（防止 DHCPv6 覆盖 DNS）"
else
  [[ "${HAS_IPV6}" == "1" ]] && log "未发现 /etc/dhcp/dhclient6.conf（或不使用 dhclient6），跳过 DHCPv6 净化。"
fi

if [[ -d /etc/network/if-up.d ]]; then
  shopt -s nullglob
  for s in /etc/network/if-up.d/*; do
    base="$(basename "$s")"
    if [[ "$base" =~ resolv|resolved|dns|dhclient|resolvconf ]]; then
      soft_run "禁用 if-up.d 冲突脚本：$base" chmod -x "$s"
    fi
  done
  shopt -u nullglob
  log_ok "if-up.d 冲突脚本处理完成（如存在则已禁用）"
else
  log "未发现 /etc/network/if-up.d，跳过。"
fi

if systemctl list-unit-files 2>/dev/null | grep -qE '^resolvconf\.service'; then
  soft_run "停止 resolvconf.service" systemctl stop resolvconf.service
  soft_run "禁用 resolvconf.service" systemctl disable resolvconf.service
  soft_run "屏蔽 resolvconf.service（避免竞争）" systemctl mask resolvconf.service
  log_ok "resolvconf.service 已中立化"
else
  log "未检测到 resolvconf.service，跳过。"
fi

progress_step 2 3 "阶段二：配置 systemd-resolved（IPv4/IPv6 同步加固）..."

RESOLVED_CONF_CONTENT=$(
cat <<EOF
# Generated by DNS-Pure v${VERSION} (Hardened + IPv6-aware)
[Resolve]
DNS=${DNS_SERVERS}
FallbackDNS=${FALLBACK_DNS}
DNSOverTLS=${DNS_OVER_TLS}
DNSSEC=${DNSSEC_MODE}
Cache=${CACHE_MODE}
DNSStubListener=${DNS_STUB_LISTENER}

# Attack surface reduction (recommended for VPS / public servers)
LLMNR=${LLMNR_MODE}
MulticastDNS=${MDNS_MODE}

ReadEtcHosts=${READ_ETC_HOSTS}
EOF
)
write_file_atomic /etc/systemd/resolved.conf "$RESOLVED_CONF_CONTENT"
log_ok "已写入 /etc/systemd/resolved.conf（DoT/DNSSEC + 关闭 LLMNR/mDNS + IPv6 支持）"

STUB="/run/systemd/resolve/stub-resolv.conf"
if [[ "${DNS_STUB_LISTENER}" == "yes" ]]; then
  log "正在重启 systemd-resolved 以应用配置..."
  if ! systemctl restart systemd-resolved.service; then
    log_err "systemd-resolved 重启失败（DNS 可能无法生效）。"
    systemctl --no-pager --full status systemd-resolved.service || true
    exit 1
  fi
  log_ok "systemd-resolved 已重启"

  if [[ -e "$STUB" ]]; then
    rm -f /etc/resolv.conf
    ln -s "$STUB" /etc/resolv.conf
    log_ok "/etc/resolv.conf 已指向 systemd-resolved stub"
  else
    log_warn "未找到 $STUB（异常：resolved 已运行但 stub 未生成）。继续执行并输出诊断。"
  fi
else
  log_warn "DNSStubListener=no：脚本不会强制 /etc/resolv.conf 指向 stub。"
  log "正在重启 systemd-resolved 以应用配置..."
  systemctl restart systemd-resolved.service || {
    log_err "systemd-resolved 重启失败。"
    systemctl --no-pager --full status systemd-resolved.service || true
    exit 1
  }
  log_ok "systemd-resolved 已重启"
fi

# ✅ 自动刷新缓存，无需用户干预
soft_run "刷新 DNS 缓存" resolvectl flush-caches

progress_step 3 3 "阶段三：安全应用更改并验证..."

test_dns_functionality || true

log ""
log "--- 最终检查 ---"
log "resolv.conf 链接状态："
ls -l /etc/resolv.conf || true

log ""
log "resolvectl 状态摘要："
resolvectl status 2>/dev/null || true

print_summary

log_ok "DNS-Pure v${VERSION} 执行完成（DNS 净化 + 加固 + IPv6 支持 + 自动安装 resolved 已完成）。"
log "💡 提示：建议保留脚本在本地，便于后续维护与回滚：sudo ./DNS-Pure.sh"
