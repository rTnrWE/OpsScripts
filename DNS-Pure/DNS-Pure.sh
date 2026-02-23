#!/usr/bin/env bash
# DNS-Pure v2.8 (Hardened + IPv6-aware)
# One-command, simple, resilient DNS "purify + harden" using systemd-resolved.
# - Default hardening: LLMNR=no, MulticastDNS=no  (attack surface reduction)
# - IPv6-aware: if IPv6 is present, automatically add IPv6 DoT resolvers & harden DHCPv6 overrides
# - Resilient: networking restart is BEST-EFFORT and never blocks DNS success

set -euo pipefail

VERSION="2.8"

# =========================
# Logging helpers
# =========================
ts() { date "+%F %T"; }
log() { echo -e "[$(ts)] $*"; }
log_ok() { echo -e "[$(ts)] ✅ $*"; }
log_warn() { echo -e "[$(ts)] ⚠️  $*"; }
log_err() { echo -e "[$(ts)] ❌ $*" >&2; }

# Run command but never fail the whole script
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
    log_err "请用 root 运行：sudo bash $0"
    exit 1
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

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
  tmp="$(mktemp)"
  printf "%s\n" "$content" > "$tmp"
  install -m 0644 "$tmp" "$path"
  rm -f "$tmp"
}

# =========================
# IPv6 detection
# =========================
has_ipv6() {
  # Consider IPv6 "present" if we have a global IPv6 address OR a default route.
  # (Some VPS have address but no route temporarily; either way, adding v6 resolvers is harmless.)
  ip -6 addr show scope global 2>/dev/null | grep -q "inet6" && return 0
  ip -6 route show default 2>/dev/null | grep -q . && return 0
  return 1
}

# =========================
# User-tunable knobs (optional)
# =========================
# Networking apply policy: default SAFE (no hard restart).
# Set to 1 only if you insist:
#   APPLY_NETWORK_REFRESH=1 curl ... | bash
APPLY_NETWORK_REFRESH="${APPLY_NETWORK_REFRESH:-0}"

# If you want the script to install ifupdown2 when missing (to use ifreload -a), set:
#   INSTALL_IFUPDOWN2=1
INSTALL_IFUPDOWN2="${INSTALL_IFUPDOWN2:-0}"

# systemd-resolved knobs (hardened defaults)
DNS_OVER_TLS="${DNS_OVER_TLS:-yes}"              # yes | opportunistic | no
DNSSEC_MODE="${DNSSEC_MODE:-yes}"                # yes | allow-downgrade | no
CACHE_MODE="${CACHE_MODE:-yes}"                  # yes | no
DNS_STUB_LISTENER="${DNS_STUB_LISTENER:-yes}"    # yes | no
LLMNR_MODE="${LLMNR_MODE:-no}"                   # Hardened default: no
MDNS_MODE="${MDNS_MODE:-no}"                     # systemd-resolved uses MulticastDNS=
READ_ETC_HOSTS="${READ_ETC_HOSTS:-yes}"          # keep /etc/hosts

# Default resolvers (DoT-capable)
# If the user exports DNS_SERVERS / FALLBACK_DNS, we will not override them.
DEFAULT_DNS_V4="1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 8.8.8.8#dns.google 8.8.4.4#dns.google"
DEFAULT_DNS_V6="2606:4700:4700::1111#cloudflare-dns.com 2606:4700:4700::1001#cloudflare-dns.com 2001:4860:4860::8888#dns.google 2001:4860:4860::8844#dns.google"

DEFAULT_FALLBACK_V4="9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net"
DEFAULT_FALLBACK_V6="2620:fe::fe#dns.quad9.net 2620:fe::9#dns.quad9.net"

# Respect user overrides if present; otherwise auto-build (IPv6-aware)
DNS_SERVERS="${DNS_SERVERS:-}"
FALLBACK_DNS="${FALLBACK_DNS:-}"

# =========================
# Main
# =========================
need_root

log "--- DNS-Pure v${VERSION} (Hardened + IPv6-aware) ---"
log "--- 开始执行全面系统DNS健康检查 ---"

# Core dependency check
if ! cmd_exists systemctl; then
  log_err "未发现 systemctl（该脚本依赖 systemd / systemd-resolved）。"
  exit 1
fi

if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved\.service'; then
  log_ok "检测到 systemd-resolved.service"
else
  log_err "未检测到 systemd-resolved.service（你的系统可能没有 systemd-resolved）。"
  exit 1
fi

# IPv6 presence
HAS_IPV6=0
if has_ipv6; then
  HAS_IPV6=1
  log_ok "检测到 IPv6（将对 IPv6 同步净化/加固，并加入 IPv6 DoT 解析器）"
else
  log "未检测到有效 IPv6（仅对 IPv4 执行解析器配置；仍会硬化系统设置）。"
fi

# Build default DNS lists if not overridden
if [[ -z "${DNS_SERVERS}" ]]; then
  if [[ "${HAS_IPV6}" == "1" ]]; then
    DNS_SERVERS="${DEFAULT_DNS_V4} ${DEFAULT_DNS_V6}"
  else
    DNS_SERVERS="${DEFAULT_DNS_V4}"
  fi
fi

if [[ -z "${FALLBACK_DNS}" ]]; then
  if [[ "${HAS_IPV6}" == "1" ]]; then
    FALLBACK_DNS="${DEFAULT_FALLBACK_V4} ${DEFAULT_FALLBACK_V6}"
  else
    FALLBACK_DNS="${DEFAULT_FALLBACK_V4}"
  fi
fi

# Show current resolv.conf mode (non-fatal)
if [[ -L /etc/resolv.conf ]]; then
  log_ok "/etc/resolv.conf 当前为软链接：$(readlink -f /etc/resolv.conf)"
else
  log_warn "/etc/resolv.conf 当前不是软链接（后续将净化为 systemd-resolved stub）。"
fi

log ""
log "--- 开始执行DNS净化与安全加固流程 ---"
log "--> 阶段一：正在清除所有潜在的DNS冲突源..."

# Backups
backup_file /etc/systemd/resolved.conf
backup_file /etc/resolv.conf
backup_file /etc/dhcp/dhclient.conf
backup_file /etc/dhcp/dhclient6.conf

# 1) dhclient (IPv4): prevent overwriting resolv.conf (best-effort)
if [[ -f /etc/dhcp/dhclient.conf ]]; then
  if grep -qE '^\s*supersede\s+domain-name-servers' /etc/dhcp/dhclient.conf; then
    soft_run "净化 dhclient.conf（更新 supersede domain-name-servers）" \
      sed -i -E 's/^\s*supersede\s+domain-name-servers.*/supersede domain-name-servers 127.0.0.53;/' /etc/dhcp/dhclient.conf
  else
    soft_run "净化 dhclient.conf（追加 supersede domain-name-servers）" \
      bash -c 'printf "\n# Added by DNS-Pure v'"$VERSION"'\nsupersede domain-name-servers 127.0.0.53;\n" >> /etc/dhcp/dhclient.conf'
  fi
  log_ok "dhclient.conf 已净化（防止 DHCPv4 覆盖 DNS）"
else
  log "未发现 /etc/dhcp/dhclient.conf，跳过 DHCPv4 净化。"
fi

# 2) dhclient6 (IPv6): prevent overwriting resolv.conf via DHCPv6 (best-effort, only if file exists)
# Note: Some setups use dhclient for v6; others use systemd-networkd/NetworkManager (not here), or no DHCPv6 at all.
if [[ "${HAS_IPV6}" == "1" && -f /etc/dhcp/dhclient6.conf ]]; then
  if grep -qE '^\s*supersede\s+domain-name-servers' /etc/dhcp/dhclient6.conf; then
    soft_run "净化 dhclient6.conf（更新 supersede domain-name-servers）" \
      sed -i -E 's/^\s*supersede\s+domain-name-servers.*/supersede domain-name-servers 127.0.0.53;/' /etc/dhcp/dhclient6.conf
  else
    soft_run "净化 dhclient6.conf（追加 supersede domain-name-servers）" \
      bash -c 'printf "\n# Added by DNS-Pure v'"$VERSION"'\nsupersede domain-name-servers 127.0.0.53;\n" >> /etc/dhcp/dhclient6.conf'
  fi
  log_ok "dhclient6.conf 已净化（防止 DHCPv6 覆盖 DNS）"
else
  [[ "${HAS_IPV6}" == "1" ]] && log "未发现 /etc/dhcp/dhclient6.conf（或不使用 dhclient6），跳过 DHCPv6 净化。"
fi

# 3) if-up.d hooks that overwrite resolv.conf (best-effort)
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

# 4) resolvconf service (if exists) – mask to avoid fights (best-effort)
if systemctl list-unit-files 2>/dev/null | grep -qE '^resolvconf\.service'; then
  soft_run "停止 resolvconf.service" systemctl stop resolvconf.service
  soft_run "禁用 resolvconf.service" systemctl disable resolvconf.service
  soft_run "屏蔽 resolvconf.service（避免竞争）" systemctl mask resolvconf.service
  log_ok "resolvconf.service 已中立化"
else
  log "未检测到 resolvconf.service，跳过。"
fi

log ""
log "--> 阶段二：正在配置 systemd-resolved（IPv4/IPv6 同步加固）..."

# Ensure enabled & running
systemctl enable systemd-resolved.service >/dev/null 2>&1 || true
systemctl start systemd-resolved.service >/dev/null 2>&1 || true
log_ok "已启用并启动 systemd-resolved"

# Write resolved.conf (explicit + hardened)
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

# Keep local hosts file honored
ReadEtcHosts=${READ_ETC_HOSTS}
EOF
)
write_file_atomic /etc/systemd/resolved.conf "$RESOLVED_CONF_CONTENT"
log_ok "已写入 /etc/systemd/resolved.conf（DoT/DNSSEC + 关闭 LLMNR/mDNS + IPv6 支持）"

# Force /etc/resolv.conf to point to resolved stub (safe & standard)
STUB="/run/systemd/resolve/stub-resolv.conf"
if [[ "${DNS_STUB_LISTENER}" == "yes" ]]; then
  if [[ -e "$STUB" ]]; then
    if [[ -L /etc/resolv.conf ]]; then
      cur="$(readlink -f /etc/resolv.conf || true)"
      if [[ "$cur" != "$STUB" ]]; then
        rm -f /etc/resolv.conf
        ln -s "$STUB" /etc/resolv.conf
      fi
    else
      rm -f /etc/resolv.conf
      ln -s "$STUB" /etc/resolv.conf
    fi
    log_ok "/etc/resolv.conf 已指向 systemd-resolved stub"
  else
    log_warn "未找到 $STUB（稍后重启 resolved 后可能生成）。继续执行。"
  fi
else
  log_warn "DNSStubListener=no：脚本不会强制 /etc/resolv.conf 指向 stub。"
fi

# Restart resolved (must succeed)
log "正在重启 systemd-resolved 以应用配置..."
if ! systemctl restart systemd-resolved.service; then
  log_err "systemd-resolved 重启失败（DNS 可能无法生效）。"
  systemctl --no-pager --full status systemd-resolved.service || true
  exit 1
fi
log_ok "systemd-resolved 已重启"

# Retry stub link once more (best-effort)
if [[ "${DNS_STUB_LISTENER}" == "yes" && -e "$STUB" ]]; then
  if [[ ! -L /etc/resolv.conf || "$(readlink -f /etc/resolv.conf || true)" != "$STUB" ]]; then
    soft_run "修复 /etc/resolv.conf -> stub-resolv.conf" bash -c "rm -f /etc/resolv.conf && ln -s '$STUB' /etc/resolv.conf"
  fi
fi

# Flush caches (best-effort)
soft_run "刷新 DNS 缓存" resolvectl flush-caches

log ""
log "--> 阶段三：正在安全地应用更改（强韧模式）..."

# Optional: install ifupdown2 for safer reload (best-effort)
if [[ "${INSTALL_IFUPDOWN2}" == "1" ]] && ! cmd_exists ifreload; then
  if cmd_exists apt-get; then
    soft_run "安装 ifupdown2（用于 ifreload -a）" bash -c "apt-get update -y && apt-get install -y ifupdown2"
  else
    log_warn "未发现 apt-get，跳过安装 ifupdown2。"
  fi
fi

if [[ "${APPLY_NETWORK_REFRESH}" == "1" ]]; then
  log_warn "已启用网络刷新（APPLY_NETWORK_REFRESH=1）。将尽力刷新网络，但失败不会中断脚本。"
  if cmd_exists ifreload; then
    soft_run "使用 ifreload -a 温和刷新网络" ifreload -a
  elif systemctl is-enabled --quiet networking.service 2>/dev/null; then
    soft_run "重启 networking.service（可能在部分环境报 File exists）" systemctl restart networking.service
  else
    log "networking.service 未启用或不存在，跳过网络刷新。"
  fi
else
  log "默认不重启 networking.service（远程安全策略）。如需启用：APPLY_NETWORK_REFRESH=1 ..."
fi

log ""
log "--- 最终检查 ---"
log "resolv.conf 链接状态："
ls -l /etc/resolv.conf || true

log ""
log "resolvectl 状态摘要："
resolvectl status || true

log ""
log_ok "DNS-Pure v${VERSION} 执行完成（DNS 净化 + 加固 + IPv6 支持 已完成）。"
log "提示：如你确实需要刷新 ifupdown 网络，可这样运行："
log "  APPLY_NETWORK_REFRESH=1 curl -sSL <URL> | bash"
