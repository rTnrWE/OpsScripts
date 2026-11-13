#!/usr/bin/env bash
# RustDesk Pilot - unofficial community tool
set -Eeuo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive
APP=rdpilot
ROOT=/var/lib/rdpilot
CONF=/etc/rdpilot
LOGDIR=/var/log/rdpilot
LOCK=/run/lock/rdpilot.lock
RD_DATA=/var/lib/rustdesk-server
GITHUB=https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest
SERVICES=(rustdesk-hbbs rustdesk-hbbr)
mkdir -p "$ROOT" "$CONF" "$LOGDIR"
exec 9>"$LOCK"
flock -n 9 || { echo 'Another rdpilot instance is running.'; exit 1; }
trap 'echo "[ERROR] Line $LINENO: command failed (exit $?)" >&2' ERR
say(){ printf '\n\033[1;36m%s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m%s\033[0m\n' "$*" >&2; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
confirm(){ local ans; read -r -p "$1 [y/N]: " ans || return 1; [[ "$ans" == [yY] || "$ans" == [yY][eE][sS] ]]; }
pause(){ read -r -p 'Press Enter to continue...' _ || true; }
require_root(){ [[ $EUID -eq 0 ]] || die 'Run as root: sudo bash rdpilot.sh'; }
check_os(){ . /etc/os-release; [[ "${ID:-}" == debian && "${VERSION_ID%%.*}" =~ ^[0-9]+$ && "${VERSION_ID%%.*}" -ge 12 ]] || die 'Debian 12+ only'; command -v systemctl >/dev/null || die 'systemd required'; }
packages(){ apt-get update && apt-get install -y ca-certificates curl python3 ufw iproute2 util-linux; }
installed(){ dpkg-query -W -f='${Status}' rustdesk-server-hbbs rustdesk-server-hbbr 2>/dev/null | grep -q 'install ok installed'; }
status(){ say 'Service status'; for s in "${SERVICES[@]}"; do printf '%-19s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || true)"; done; echo; dpkg-query -W rustdesk-server-hbbs rustdesk-server-hbbr 2>/dev/null || true; echo; ss -lntup | grep -E ':(21115|21116|21117|21118|21119)\b' || true; echo; free -h; df -h /; }
ssh_ports(){ { ss -H -lntp 2>/dev/null | awk '/sshd|systemd/ {print $4}' | sed -nE 's/.*:([0-9]+)$/\1/p'; command -v sshd >/dev/null && sshd -T 2>/dev/null | awk '$1=="port" {print $2}'; [[ -n "${SSH_CONNECTION:-}" ]] && awk '{print $4}' <<<"$SSH_CONNECTION"; } | awk '$1~/^[0-9]+$/ && $1>0 && $1<65536' | sort -nu; }
scan(){ say 'Listening TCP / UDP sockets'; ss -lntup || true; say 'Detected SSH ports'; ssh_ports || true; say 'UFW current rules'; ufw status numbered 2>/dev/null || true; say 'IPv6 / routing'; ip -brief addr; ip route show default || true; ip -6 route show default || true; say 'Other firewall managers'; command -v docker >/dev/null && docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null || true; command -v nft >/dev/null && nft list ruleset 2>/dev/null | head -n 45 || true; }
# Use UFW application-profile-independent rule snapshots. Never reset or flush other firewall tables.
fw_backup(){ local dest="$1"; mkdir -p "$dest"; cp -a /etc/ufw "$dest/ufw"; ufw status numbered >"$dest/ufw-status.txt" 2>&1 || true; ufw status | head -n 1 >"$dest/ufw-initial-state.txt"; if command -v nft >/dev/null; then nft list ruleset >"$dest/nft-before.txt" 2>/dev/null || true; fi; }
fw_guard(){
 local dir="$1" unit="rdpilot-fw-rollback-$(date +%s)"
 cat >"$dir/rollback.sh" <<EOF
#!/bin/bash
set -eu
cp -a "$dir/ufw/." /etc/ufw/
if grep -qi '^Status: inactive' "$dir/ufw-initial-state.txt"; then
  ufw --force disable
else
  ufw --force enable
  ufw reload
fi
EOF
 chmod 700 "$dir/rollback.sh"
 command -v systemd-run >/dev/null || die 'systemd-run required for firewall rollback'
 systemd-run --unit="$unit" --on-active=180s --property=Type=oneshot /bin/bash "$dir/rollback.sh" >/dev/null || die 'Failed to arm rollback; firewall unchanged'
 printf '%s' "$unit" >"$dir/rollback-unit"
 warn "Automatic UFW rollback armed for 180 seconds: $unit"
}
fw_commit(){ local dir="$1" unit; unit=$(cat "$dir/rollback-unit"); systemctl stop "${unit}.timer" 2>/dev/null || true; systemctl reset-failed "${unit}.service" 2>/dev/null || true; echo 'Firewall changes committed. Backup:' "$dir"; }
fw_manage(){
 check_os
 command -v ufw >/dev/null || { say 'Installing UFW'; apt-get update; apt-get install -y ufw iproute2; }
 scan
 warn 'IMPORTANT: Listening sockets are not necessarily public services. UFW cannot protect cloud security groups or other independent firewall managers.'
 warn 'Strict mode reviews the existing numbered rules. Docker/nftables forwarding may bypass UFW; inspect manually.'
 local ssh=() p extra line proto port choice idx
 mapfile -t ssh < <(ssh_ports)
 ((${#ssh[@]})) || die 'SSH port not confidently detected; firewall changes refused.'
 printf 'SSH protection ports: %s\n' "${ssh[*]}"
 echo 'Required RustDesk: 21115/tcp 21116/tcp 21116/udp 21117/tcp'
 echo 'Enter ADDITIONAL public inbound ports to retain (e.g. 443/tcp 443/udp).'
 read -r -p 'Additional ports [blank=none]: ' extra || return
 local allow=(21115/tcp 21116/tcp 21116/udp 21117/tcp)
 for p in "${ssh[@]}"; do allow+=("$p/tcp"); done
 for p in $extra; do
   [[ "$p" =~ ^([0-9]{1,5})/(tcp|udp)$ ]] || { warn "Invalid: $p"; return 1; }
   ((10#${BASH_REMATCH[1]} >= 1 && 10#${BASH_REMATCH[1]} <= 65535)) || { warn 'Invalid port'; return 1; }
   allow+=("$p")
 done
 say 'Allowed inbound ports to add / retain'; printf '  %s\n' "${allow[@]}"
 echo; echo 'EXISTING UFW RULES (review any rules to REMOVE):'; ufw status numbered || true
 echo 'Strict mode removes only explicitly selected existing UFW rules, not arbitrary nftables/iptables rules.'
 read -r -p 'Existing UFW rule NUMBERS to delete (space separated, blank=keep all): ' line || return
 local nums=() n max
 max=$(ufw status numbered | grep -Ec '^\[ *[0-9]+\]' || true)
 for n in $line; do [[ "$n" =~ ^[0-9]+$ ]] && ((n>=1 && n<=max)) || { warn "Invalid rule number: $n"; return 1; }; nums+=("$n"); done
 if ((${#nums[@]})); then mapfile -t nums < <(printf '%s\n' "${nums[@]}" | sort -rnu); fi
 echo 'Proposed deletions:'; printf '  rule #%s\n' "${nums[@]:-none}"
 warn 'UFW default incoming will become DENY; outgoing ALLOW. Forwarding rules and IPv6 must be reviewed separately.'
 confirm 'Apply these exact changes with 180-second rollback guard?' || return
 local dir="$ROOT/fw-backup-$(date +%Y%m%d-%H%M%S)"; fw_backup "$dir"; fw_guard "$dir"
 local armed_at; armed_at=$(date +%s)
 local ok=1
 for n in "${nums[@]}"; do ufw --force delete "$n" || ok=0; done
 for p in "${allow[@]}"; do ufw allow "$p" || ok=0; done
 ufw default deny incoming || ok=0
 ufw default allow outgoing || ok=0
 ufw --force enable || ok=0
 ufw status verbose || true
 if ((ok==0)); then warn 'Some firewall operations failed; rollback remains armed.'; return 1; fi
 warn 'OPEN A SECOND SSH SESSION NOW. Do not confirm until you have successfully logged in again.'
 if (( $(date +%s) - armed_at >= 170 )); then warn 'Rollback window expired; do not commit. Recheck firewall.'; return 1; fi
 confirm 'Second SSH connection verified and rules accepted? (otherwise auto-rollback)' && fw_commit "$dir" || warn 'Not committed: automatic rollback will run within 180 seconds.'
}
latest_json(){ curl -fsSL --connect-timeout 10 --max-time 40 -H 'Accept: application/vnd.github+json' -H 'User-Agent: RustDesk-Pilot' "$GITHUB"; }
release_info(){
 local arch; arch=$(dpkg --print-architecture)
 [[ "$arch" == amd64 || "$arch" == arm64 ]] || die "Unsupported architecture: $arch"
 local json="$1" output="$2"
 python3 - "$json" "$arch" >"$output" <<'PY'
import json,sys,re
j=json.load(open(sys.argv[1])); arch=sys.argv[2]
tag=j.get('tag_name','')
if j.get('draft') or j.get('prerelease') or not re.fullmatch(r'\d+\.\d+\.\d+(?:-\d+)?',tag): raise SystemExit('Unsupported or non-stable release tag')
print('VERSION='+tag)
for component in ('hbbs','hbbr'):
 name=f'rustdesk-server-{component}_{tag}_{arch}.deb'
 a=next((x for x in j.get('assets',[]) if x.get('name')==name),None)
 if not a: raise SystemExit('Missing official DEB: '+name)
 digest=a.get('digest','')
 if not re.fullmatch(r'sha256:[a-fA-F0-9]{64}',digest): raise SystemExit('Missing GitHub asset SHA256 digest for '+name)
 url=a.get('browser_download_url','')
 if url!=f'https://github.com/rustdesk/rustdesk-server/releases/download/{tag}/{name}': raise SystemExit('Unexpected asset URL')
 print(component.upper()+'_URL='+url)
 print(component.upper()+'_SHA='+digest[7:].lower())
PY
}
fetch_release(){
 command -v python3 >/dev/null && command -v curl >/dev/null || die 'python3 and curl required; run install prerequisites first'
 local dir="$1"; mkdir -p "$dir"; latest_json >"$dir/release.json" || die 'Cannot query official GitHub Releases API'
 release_info "$dir/release.json" "$dir/release.env" || die 'Release metadata verification failed'
 # Strictly validate the generated assignments before sourcing.
 grep -Eq '^VERSION=[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$' "$dir/release.env" || die 'Invalid version'
 source "$dir/release.env"
 say "Official stable release: $VERSION"
 curl -fL --retry 3 --connect-timeout 15 "$HBBS_URL" -o "$dir/hbbs.deb"
 curl -fL --retry 3 --connect-timeout 15 "$HBBR_URL" -o "$dir/hbbr.deb"
 (cd "$dir" && printf '%s  %s\n' "$HBBS_SHA" hbbs.deb "$HBBR_SHA" hbbr.deb | sha256sum -c -) || die 'SHA256 mismatch; installation stopped'
 for component in hbbs hbbr; do
   [[ "$(dpkg-deb -f "$dir/$component.deb" Package)" == "rustdesk-server-$component" ]] || die 'DEB package identity mismatch'
   [[ "$(dpkg-deb -f "$dir/$component.deb" Version)" == "$VERSION" ]] || die 'DEB package version mismatch'
 done
}
log_off(){
 for s in "${SERVICES[@]}"; do mkdir -p "/etc/systemd/system/$s.service.d"; cat >"/etc/systemd/system/$s.service.d/90-rdpilot-logging.conf" <<'EOF'
[Service]
StandardOutput=null
StandardError=null
EOF
 done
 systemctl daemon-reload
 for s in "${SERVICES[@]}"; do systemctl try-restart "$s"; done
}
log_on(){
 for s in "${SERVICES[@]}"; do mkdir -p "/etc/systemd/system/$s.service.d"; cat >"/etc/systemd/system/$s.service.d/90-rdpilot-logging.conf" <<'EOF'
[Service]
StandardOutput=journal
StandardError=journal
EOF
 done
 systemctl daemon-reload
 for s in "${SERVICES[@]}"; do systemctl try-restart "$s"; done
}
# Durable 30-minute debug expiration: the persistent timer rechecks the absolute epoch after reboot.
install_log_timer(){
 cat >/etc/systemd/system/rdpilot-log-restore.service <<'EOF'
[Unit]
Description=RustDesk Pilot restore quiet logging after debug deadline
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rdpilot --log-restore-check
EOF
 cat >/etc/systemd/system/rdpilot-log-restore.timer <<'EOF'
[Unit]
Description=RustDesk Pilot debug logging expiration monitor
[Timer]
OnBootSec=1min
OnUnitInactiveSec=1min
AccuracySec=30s
Unit=rdpilot-log-restore.service
[Install]
WantedBy=timers.target
EOF
 systemctl daemon-reload
 systemctl enable --now rdpilot-log-restore.timer >/dev/null
}
log_restore_check(){
 [[ -f "$CONF/debug-until" ]] || return 0
 local deadline; deadline=$(cat "$CONF/debug-until")
 [[ "$deadline" =~ ^[0-9]+$ ]] || return 1
 if (( $(date +%s) >= deadline )); then log_off; rm -f "$CONF/debug-until"; fi
}
logging_menu(){
 echo '1) Disable application logs (default)'; echo '2) Enable debug logging for 30 minutes'; echo '3) Follow journal'; echo '4) View logging status'
 local x; read -r -p 'Choose: ' x || return
 case "$x" in
 1) rm -f "$CONF/debug-until"; log_off; echo 'Application stdout/stderr disabled.';;
 2) [[ -x /usr/local/sbin/rdpilot ]] || die 'Install rdpilot to /usr/local/sbin/rdpilot first'; install_log_timer; date -d '+30 minutes' +%s >"$CONF/debug-until"; log_on; echo 'Debug active for 30 minutes; timer restores quiet mode.';;
 3) journalctl -fu rustdesk-hbbs -u rustdesk-hbbr;;
 4) systemctl show rustdesk-hbbs rustdesk-hbbr -p StandardOutput -p StandardError; [[ -f "$CONF/debug-until" ]] && date -d "@$(cat "$CONF/debug-until")" || true;;
 esac
}
backup(){
 installed || die 'RustDesk not installed'
 local dir="$ROOT/backups/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$dir"
 dpkg-query -W rustdesk-server-hbbs rustdesk-server-hbbr >"$dir/versions.txt"
 for s in "${SERVICES[@]}"; do systemctl cat "$s" >"$dir/$s.service.txt"; done
 systemctl stop "${SERVICES[@]}"
 local ok=1
 cp -a "$RD_DATA" "$dir/data" || ok=0
 systemctl start "${SERVICES[@]}" || ok=0
 ((ok==1)) || die "Backup/start failed. Inspect $dir"
 echo "$dir" >"$ROOT/last-backup"
 say "Backup: $dir"; echo 'Export this root-only directory off-server for disaster recovery.'
}
install_or_upgrade(){
 check_os; packages
 local existing=0; installed && existing=1
 if ((existing)); then
   say 'Existing RustDesk installation detected'; dpkg-query -W rustdesk-server-hbbs rustdesk-server-hbbr
   confirm 'Proceed to manually check and potentially upgrade?' || return
 else
   [[ ! -e "$RD_DATA/id_ed25519" ]] || die 'Existing key found without installed packages. Manual recovery required; refusing to overwrite.'
   confirm 'Install official RustDesk OSS DEB packages?' || return
 fi
 local dir; dir=$(mktemp -d "$ROOT/download.XXXXXXXX"); fetch_release "$dir"
 source "$dir/release.env"
 if ((existing)); then
   local current; current=$(dpkg-query -W -f='${Version}' rustdesk-server-hbbs 2>/dev/null || true)
   if [[ "$current" == "$VERSION" ]]; then echo "Already running package version $VERSION"; return; fi
   warn "Installed: $current; latest: $VERSION"
   confirm 'Back up data and upgrade both services?' || return
   backup
 else
   confirm "Install verified RustDesk $VERSION now?" || return
 fi
 # Keep the verified packages for manual rollback.
 local archive="$ROOT/packages/$VERSION"; mkdir -p "$archive"; cp -a "$dir/hbbs.deb" "$dir/hbbr.deb" "$dir/release.env" "$archive/"
 apt-get install -y "$dir/hbbs.deb" "$dir/hbbr.deb"
 systemctl daemon-reload
 systemctl enable --now "${SERVICES[@]}"
 log_off
 systemctl restart "${SERVICES[@]}"
 status
 [[ -s "$RD_DATA/id_ed25519.pub" ]] || die 'Public key not generated; inspect service logs after enabling debug'
 for s in "${SERVICES[@]}"; do systemctl is-active --quiet "$s" || die "$s inactive"; done
 say 'Installed successfully. Configure firewall separately using menu 7 if not yet approved.'
 show_config
}
valid_host(){ [[ "$1" =~ ^[A-Za-z0-9.:-]+$ && "$1" != *..* && "$1" != -* ]]; }
show_config(){
 [[ -s "$RD_DATA/id_ed25519.pub" ]] || { warn 'Public key not found'; return 1; }
 local ip='' key; key=$(tr -d '\r\n' <"$RD_DATA/id_ed25519.pub")
 if [[ -f "$CONF/host" ]]; then ip=$(cat "$CONF/host"); fi
 if [[ -z "$ip" ]]; then ip=$(curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true); fi
 echo "Suggested public address: ${ip:-unknown} (may be NAT/proxy egress, verify reachability)"
 local host; read -r -p "Confirmed ID server IP/domain [${ip}]: " host || return; host=${host:-$ip}
 valid_host "$host" || { warn 'Invalid host'; return 1; }
 printf '%s\n' "$host" >"$CONF/host"
 # Official client: CustomServer {key,host,api,relay}, JSON -> URL_SAFE_NO_PAD -> reverse.
 local encoded
 encoded=$(python3 - "$host" "$key" <<'PY'
import sys,json,base64
host,key=sys.argv[1:]
payload={'key':key,'host':host,'api':'','relay':''}
raw=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
token=base64.urlsafe_b64encode(raw).decode().rstrip('=')[::-1]
assert json.loads(base64.urlsafe_b64decode(token[::-1]+'='*(-len(token)%4)))==payload
print(token)
PY
)
 say 'RustDesk client settings'
 printf 'ID Server: %s\nKey: %s\nRelay Server: (blank)\nAPI Server: (blank)\n' "$host" "$key"
 echo 'Official-compatible Import Server Config string:'
 printf '%s\n' "$encoded"
 echo 'Paste into RustDesk -> Settings -> Network -> ID/Relay Server -> Import Server Config.'
}
service_menu(){
 echo '1) Start  2) Stop  3) Restart  4) Enable at boot  5) Disable at boot'; local x; read -r -p 'Choose: ' x || return
 case "$x" in 1) systemctl start "${SERVICES[@]}";; 2) confirm 'Stop all RustDesk connections?' && systemctl stop "${SERVICES[@]}";; 3) systemctl restart "${SERVICES[@]}";; 4) systemctl enable "${SERVICES[@]}";; 5) systemctl disable "${SERVICES[@]}";; esac
 status
}
restore_menu(){
 local dir; echo 'Available backups:'; ls -1d "$ROOT"/backups/* 2>/dev/null || true
 read -r -p 'Full backup directory path to restore (blank=cancel): ' dir || return
 [[ -n "$dir" && "$dir" == "$ROOT"/backups/* && -d "$dir/data" ]] || { warn 'Invalid backup'; return; }
 warn 'Restoring an old database/key can affect client connectivity. This does not downgrade DEB packages.'
 confirm 'Restore selected backup (current data will be archived)?' || return
 local save="$ROOT/pre-restore-$(date +%Y%m%d-%H%M%S)"
 systemctl stop "${SERVICES[@]}"
 [[ ! -e "$RD_DATA" ]] || mv "$RD_DATA" "$save"
 cp -a "$dir/data" "$RD_DATA"
 systemctl start "${SERVICES[@]}"
 echo "Restore complete; previous data: $save"
}
rollback_packages(){
 echo 'Cached verified package versions:'; ls -1 "$ROOT/packages" 2>/dev/null || true
 local v; read -r -p 'Version to reinstall (blank=cancel): ' v || return
 [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$ && -f "$ROOT/packages/$v/hbbs.deb" && -f "$ROOT/packages/$v/hbbr.deb" ]] || { warn 'No cached package'; return; }
 warn 'Package rollback may be incompatible with a newer database. Restore matching backup if necessary.'
 confirm "Reinstall cached $v packages?" || return
 backup
 apt-get install -y --allow-downgrades "$ROOT/packages/$v/hbbs.deb" "$ROOT/packages/$v/hbbr.deb"
 systemctl restart "${SERVICES[@]}"; status
}
uninstall_menu(){
 installed || { echo 'RustDesk packages not installed'; return; }
 echo '1) Remove packages, keep keys/database  2) Remove packages AND keys/database'; local x; read -r -p 'Choose: ' x || return
 case "$x" in
 1) confirm 'Remove RustDesk packages?' || return; systemctl stop "${SERVICES[@]}" || true; apt-get remove -y rustdesk-server-hbbs rustdesk-server-hbbr;;
 2) warn 'IRREVERSIBLE: client identities may need reconfiguration.'; read -r -p 'Type DELETE-RUSTDESK-DATA: ' x; [[ "$x" == DELETE-RUSTDESK-DATA ]] || return; systemctl stop "${SERVICES[@]}" || true; apt-get purge -y rustdesk-server-hbbs rustdesk-server-hbbr; rm -rf -- "$RD_DATA";;
 esac
 echo 'UFW rules, rdpilot backups and other business services were not touched.'
}
main(){
 require_root; check_os
 if [[ "${1:-}" != --log-restore-check && "${1:-}" != --version ]]; then
   if [[ ! -f /usr/local/sbin/rdpilot ]] || ! cmp -s "${BASH_SOURCE[0]}" /usr/local/sbin/rdpilot; then
     if confirm 'Install/update this manager at /usr/local/sbin/rdpilot (needed for debug auto-restore)?'; then
       install -m 700 "${BASH_SOURCE[0]}" /usr/local/sbin/rdpilot
     fi
   fi
 fi
 case "${1:-}" in
 --log-restore-check) log_restore_check; return;;
 --version) echo 'RustDesk Pilot v1.0.0'; return;;
 esac
 while :; do
  printf '\n===== RustDesk Pilot v1.0.0 =====\n'
  echo '1) Install / initialize'; echo '2) Check latest / upgrade'; echo '3) Start / stop / restart'; echo '4) Status / resources'; echo '5) Client import configuration'; echo '6) Logging / 30-minute debug'; echo '7) UFW strict firewall review'; echo '8) Backup / restore / package rollback'; echo '9) Network diagnostics'; echo '10) Uninstall'; echo '0) Exit'
  local choice; read -r -p 'Select: ' choice || break
  case "$choice" in
   1|2) install_or_upgrade;; 3) service_menu;; 4) status;; 5) show_config;; 6) logging_menu;; 7) fw_manage;;
   8) echo '1) Backup 2) Restore data 3) Reinstall cached DEB'; read -r -p 'Select: ' choice || continue; case "$choice" in 1) backup;; 2) restore_menu;; 3) rollback_packages;; esac;;
   9) scan;; 10) uninstall_menu;; 0) break;; *) warn 'Invalid choice';;
  esac
  pause
 done
}
main "$@"
