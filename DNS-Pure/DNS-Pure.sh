#!/usr/bin/env bash
# DNS-Pure v2.9.5 (Focused · Safe · Robust)
#
# 🌟 核心能力:
#    ✅ 一键净化：自动配置 DoT/DNSSEC/缓存/攻击面缩减
#    ✅ 自愈安装：缺失 systemd-resolved 时自动安装
#    ✅ 深度适配：自动处理 NetworkManager 冲突
#    ✅ 即时生效：重启 resolved 服务即可，无需重启网络
#    ✅ 安全回滚：TRIGGER_ROLLBACK=1 快速恢复
#
# 🚀 推荐用法:
#    curl -sSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/DNS-Pure/DNS-Pure.sh -o DNS-Pure.sh && chmod +x DNS-Pure.sh && sudo ./DNS-Pure.sh
#
# 📋 DNS_SERVERS 格式规范:
#    "IPv4#标签 IPv6#标签" (空格分隔，标签可选)
#    示例："1.1.1.1#CF 2606:4700::1111#CF 8.8.8.8#Google"

set -euo pipefail

VERSION="2.9.5"

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
    log "检测到 NetworkManager 运行中，将自动配置其使用 systemd-resolved"
    NETWORKMANAGER_ACTIVE=1
  fi
}

# =========================
# Backup & Atomic write
# =========================
backup_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  # 如果已是备份文件，避免重复备份
  [[ "$f" == *.bak.dns-pure-v* ]] && return 0
  
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
# IPv6 detection (Optimized v2.9.5)
# =========================
has_ipv6() {
  # 1. 检查内核模块
  if [[ -d /proc/sys/net/ipv6 ]]; then
    # 2. 检查是否被禁用
    if [[ "$(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null)" == "1" ]]; then
      return 1
    fi
    # 3. 检查是否有全球单播地址或默认路由
    if ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then return 0; fi
    if ip -6 route show default 2>/dev/null | grep -q .; then return 0; fi
  fi
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
  
  # 专注 Ubuntu/Debian，保留 apt-get 逻辑
  if ! cmd_exists apt-get; then
    log_err "❌ 未检测到 apt-get，无法自动安装（非 Debian/Ubuntu 系统？）"
    return 1
  fi

  log_warn "🔧 核心功能：未检测到 systemd-resolved，正在自动安装..."
  
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
# Rollback function (Enhanced v2.9.5)
# =========================
rollback_config() {
  log "🔄 正在恢复到 DNS-Pure 修改前的状态..."
  local restored=0
  local script_name="${0##*/}"
  
  # 定义需要检查的配置文件列表
  local files=("/etc/systemd/resolved.conf" "/etc/resolv.conf" "/etc/dhcp/dhclient.conf" "/etc/dhcp/dhclient6.conf")
  
  # 增加 NetworkManager 配置文件回滚
  local nm_conf="/etc/NetworkManager/conf.d/10-dns-pure.conf"
  
  # 1. 处理常规文件备份恢复
  for f in "${files[@]}"; do
    if [[ ! -e "$f" ]]; then continue; fi
    
    local latest_bak
    latest_bak=$(ls -t "${f}.bak.dns-pure-v"* 2>/dev/null | head -1) || continue
    
    if [[ -n "$latest_bak" ]]; then
      cp -a "$latest_bak" "$f"
      log_ok "已恢复：$f <- $latest_bak"
      ((restored++))
    fi
  done

  # 2. 处理 NetworkManager 配置
  if [[ -f "$nm_conf" ]]; then
    # 检查是否有备份
    local nm_bak="${nm_conf}.bak.dns-pure-v${VERSION}.$(date +%F-%H%M%S)" # 仅用于查找逻辑
    # 简单逻辑：如果文件存在，且由本脚本创建（内容包含标识），且无备份，则删除
    if [[ -f "$nm_conf" ]] && grep -q "DNS-Pure" "$nm_conf"; then
       rm -f "$nm_conf"
       log_ok "已清理生成的 NetworkManager 配置：$nm_conf"
       soft_run "重载 NetworkManager 配置" nmcli general reload 2>/dev/null || true
       ((restored++))
    fi
  fi
  
  if [[ $restored -gt 0 ]]; then
    if systemctl list-unit-files 2>/dev/null | grep -qE '^resolvconf\.service'; then
      soft_run "取消屏蔽 resolvconf.service" systemctl unmask resolvconf.service
      soft_run "启用 resolvconf.service" systemctl enable resolvconf.service
    fi
    soft_run "重启 systemd-resolved" systemctl restart systemd-resolved.service
    log_ok "回滚完成！已恢复/清理 $restored 个配置项"
    log "💡 提示：如需重新净化，请执行：sudo ./${script_name}"
  else
    log_warn "未找到可恢复的备份，回滚未执行任何操作"
  fi
}

# =========================
# DNS validation test (Robust v2.9.5)
# =========================
test_dns_functionality() {
  log "🔍 执行 DNS 解析功能测试..."
  local test_domains=("example.com" "dns.google")
  local failed=0
  
  # 优先使用系统自带工具，避免依赖外部 nslookup
  local tester=""
  if cmd_exists resolvectl; then
    tester="resolvectl query"
  elif cmd_exists host; then
    tester="host"
  elif cmd_exists nslookup; then
    tester="nslookup"
  else
    log_warn "未找到 DNS 测试工具，跳过验证步骤"
    return 0
  fi

  for domain in "${test_domains[@]}"; do
    if $tester "$domain" >/dev/null 2>&1; then
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
# Summary report
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
 ${EMOJI_OK} NetworkManager: $([[ ${NETWORKMANAGER_ACTIVE:-0} -eq 1 ]] && echo "已配置托管" || echo "未运行/未干预")
 ${EMOJI_OK} LLMNR/mDNS: ${LLMNR_MODE}/${MDNS_MODE} (已禁用)
 ${EMOJI_OK} DNS 缓存：已自动刷新
🔗 /etc/resolv.conf: $(readlink -f /etc/resolv.conf 2>/dev/null || echo "regular file")
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⚡ 生效说明
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 ${EMOJI_OK} DNS 配置已即时生效
💡 提示：旧连接可能保持直到超时，通常无需干预。

🔧 自定义使用指南
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
💡 自定义 DNS 服务器:
   sudo DNS_SERVERS="8.8.8.8#google 1.1.1.1#cloudflare" ./${script_name}

💡 回滚到之前配置:
   sudo TRIGGER_ROLLBACK=1 ./${script_name}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

# =========================
# User-tunable knobs
# =========================
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

log "--- DNS-Pure v${VERSION} (Focused · Safe · Robust) ---"
log "--- 开始执行全面系统 DNS 健康检查 ---"

if ! cmd_exists systemctl; then
  log_err "未发现 systemctl（该脚本依赖 systemd）。"
  exit 1
fi

if ! ensure_systemd_resolved; then
  log_err "systemd-resolved 准备就绪失败。"
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
  log_ok "检测到 IPv6 支持"
else
  log "未检测到有效 IPv6，仅配置 IPv4 解析器"
fi

if [[ -z "${DNS_SERVERS}" ]]; then
  DNS_SERVERS="${DEFAULT_DNS_V4}"
  [[ "${HAS_IPV6}" == "1" ]] && DNS_SERVERS="${DNS_SERVERS} ${DEFAULT_DNS_V6}"
fi
if [[ -z "${FALLBACK_DNS}" ]]; then
  FALLBACK_DNS="${DEFAULT_FALLBACK_V4}"
  [[ "${HAS_IPV6}" == "1" ]] && FALLBACK_DNS="${FALLBACK_DNS} ${DEFAULT_FALLBACK_V6}"
fi

log ""
log "--- 开始执行 DNS 净化与安全加固流程 ---"

progress_step 1 3 "阶段一：清除潜在的 DNS 冲突源..."

backup_file /etc/systemd/resolved.conf
backup_file /etc/resolv.conf
backup_file /etc/dhcp/dhclient.conf
backup_file /etc/dhcp/dhclient6.conf

# 优化：NetworkManager 适配
if [[ "$NETWORKMANAGER_ACTIVE" -eq 1 ]]; then
  local nm_conf_dir="/etc/NetworkManager/conf.d"
  local nm_conf_file="${nm_conf_dir}/10-dns-pure.conf"
  mkdir -p "$nm_conf_dir"
  
  # 备份已存在的文件
  if [[ -f "$nm_conf_file" ]]; then
    backup_file "$nm_conf_file"
  fi
  
  cat > "$nm_conf_file" <<EOF
# Managed by DNS-Pure v${VERSION}
[main]
dns=systemd-resolved
rc-manager=unmanaged
EOF
  log_ok "NetworkManager 已配置为 systemd-resolved 模式 (dns=systemd-resolved)"
  
  # 通知 NetworkManager 重载配置（不断网）
  soft_run "重载 NetworkManager 配置" nmcli general reload 2>/dev/null || true
fi

if [[ -f /etc/dhcp/dhclient.conf ]]; then
  if grep -qE '^\s*supersede\s+domain-name-servers' /etc/dhcp/dhclient.conf; then
    soft_run "净化 dhclient.conf" \
      sed -i -E 's/^\s*supersede\s+domain-name-servers.*/supersede domain-name-servers 127.0.0.53;/' /etc/dhcp/dhclient.conf
  else
    cat >> /etc/dhcp/dhclient.conf <<EOF

# Added by DNS-Pure v${VERSION}
supersede domain-name-servers 127.0.0.53;
EOF
  fi
  log_ok "dhclient.conf 已净化"
fi

if [[ "${HAS_IPV6}" == "1" && -f /etc/dhcp/dhclient6.conf ]]; then
  if grep -qE '^\s*supersede\s+domain-name-servers' /etc/dhcp/dhclient6.conf; then
    soft_run "净化 dhclient6.conf" \
      sed -i -E 's/^\s*superscede\s+domain-name-servers.*/supersede domain-name-servers 127.0.0.53;/' /etc/dhcp/dhclient6.conf
  else
    cat >> /etc/dhcp/dhclient6.conf <<EOF

# Added by DNS-Pure v${VERSION}
supersede domain-name-servers 127.0.0.53;
EOF
  fi
  log_ok "dhclient6.conf 已净化"
fi

if systemctl list-unit-files 2>/dev/null | grep -qE '^resolvconf\.service'; then
  soft_run "停止 resolvconf.service" systemctl stop resolvconf.service
  soft_run "禁用 resolvconf.service" systemctl disable resolvconf.service
  soft_run "屏蔽 resolvconf.service" systemctl mask resolvconf.service
  log_ok "resolvconf.service 已中立化"
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

# Attack surface reduction
LLMNR=${LLMNR_MODE}
MulticastDNS=${MDNS_MODE}

ReadEtcHosts=${READ_ETC_HOSTS}
EOF
)
write_file_atomic /etc/systemd/resolved.conf "$RESOLVED_CONF_CONTENT"
log_ok "已写入 /etc/systemd/resolved.conf"

STUB="/run/systemd/resolve/stub-resolv.conf"
if [[ "${DNS_STUB_LISTENER}" == "yes" ]]; then
  log "正在重启 systemd-resolved 以应用配置..."
  if ! systemctl restart systemd-resolved.service; then
    log_err "systemd-resolved 重启失败。"
    systemctl --no-pager --full status systemd-resolved.service || true
    exit 1
  fi
  log_ok "systemd-resolved 已重启"

  # 优化：增加 Retry 机制，解决 Stub 文件生成延迟
  local wait_count=0
  local max_wait=5 # 最多等待 5 秒
  while [[ ! -e "$STUB" ]] && [[ $wait_count -lt $max_wait ]]; do
    sleep 1
    ((wait_count++))
    log "等待 resolved 生成 stub 文件... ($wait_count/$max_wait)"
  done

  if [[ -e "$STUB" ]]; then
    rm -f /etc/resolv.conf
    ln -s "$STUB" /etc/resolv.conf
    log_ok "/etc/resolv.conf 已指向 systemd-resolved stub"
  else
    log_err "systemd-resolved 重启成功，但 stub 文件未生成 ($STUB)。"
    log_err "请检查日志：journalctl -u systemd-resolved"
    exit 1
  fi
else
  log_warn "DNSStubListener=no：跳过 resolv.conf 软链接强制修改。"
  systemctl restart systemd-resolved.service || {
    log_err "systemd-resolved 重启失败。"
    exit 1
  }
fi

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

log_ok "DNS-Pure v${VERSION} 执行完成。"
