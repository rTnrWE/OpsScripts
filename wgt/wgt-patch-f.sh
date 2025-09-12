#!/bin/bash

#====================================================================================
# wgt-patch.sh - fscarmen WARP Zero Trust Account Fix Patch
#
#   Description: A patch script to fix the Zero Trust (Teams) account issue
#                for the fscarmen/warp-sh script by using wgcf to fetch official
#                and reliable configuration data.
#   Author:      Gemini & Collaborator
#   Version:     1.0.0
#
#====================================================================================

# --- Colors for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Global Variables ---
SCRIPT_VERSION="1.0.0"
FSCARMEN_DIR="/etc/wireguard"
WGCF_PROFILE_PATH="${FSCARMEN_DIR}/wgcf-profile.conf"
WGCF_ACCOUNT_PATH="${FSCARMEN_DIR}/wgcf-teams.json" # Use a distinct name for the raw account file
FSCARMEN_ACCOUNT_DB="${FSCARMEN_DIR}/warp-account.conf"
FSCARMEN_WARP_CONF="${FSCARMEN_DIR}/warp.conf"
FSCARMEN_PROXY_CONF="${FSCARMEN_DIR}/proxy.conf"

# --- Utility Functions ---
info() { echo -e "${GREEN}[INFO] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
error() { echo -e "${RED}[ERROR] $*${NC}"; exit 1; }
pause_for_user() { read -rp "Press [Enter] to continue..."; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root. Please use 'sudo ./wgt-patch.sh'."
    fi
}

check_fscarmen() {
    if [ ! -f "${FSCARMEN_DIR}/menu.sh" ]; then
        error "fscarmen/warp-sh script not found at '${FSCARMEN_DIR}/menu.sh'. Please install it first."
    fi
    info "fscarmen/warp-sh installation detected."
}

install_dependency() {
    local dep_name=$1
    local install_cmd=$2
    if ! command -v "$dep_name" &> /dev/null; then
        info "Installing dependency: ${dep_name}..."
        if ! ${install_cmd}; then
            error "Failed to install ${dep_name}. Please install it manually."
        fi
        info "${dep_name} installed successfully."
    fi
}

# --- Core Logic ---

prepare_environment() {
    info "Preparing environment and installing necessary dependencies..."
    install_dependency "wget" "apt-get update && apt-get install -y wget"
    install_dependency "jq" "apt-get install -y jq"
    
    # Download and install wgcf
    if ! command -v "wgcf" &> /dev/null; then
        info "Downloading and installing wgcf..."
        local arch
        case $(uname -m) in
            aarch64) arch="arm64" ;;
            x86_64) arch="amd64" ;;
            *) error "Unsupported architecture: $(uname -m)" ;;
        esac
        wget -O /usr/local/bin/wgcf "https://github.com/ViRb3/wgcf/releases/download/v2.2.19/wgcf_2.2.19_linux_${arch}"
        if [ $? -ne 0 ]; then
            error "Failed to download wgcf. Please check your network."
        fi
        chmod +x /usr/local/bin/wgcf
        info "wgcf installed successfully."
    fi
}

get_zero_trust_config() {
    info "Starting the process to fetch official Zero Trust configuration..."
    warn "----------------------------------------------------------------"
    warn " IMPORTANT: A browser-based login is required."
    warn "----------------------------------------------------------------"
    
    read -rp "Please enter your Cloudflare Zero Trust Team Name (e.g., 'onedgex'): " TEAM_NAME
    if [ -z "${TEAM_NAME}" ]; then
        error "Team Name cannot be empty."
    fi

    info "Running wgcf-teams to register a new device..."
    info "Please follow the on-screen instructions, open the URL in your local browser, and authenticate."
    
    wgcf-teams --team-name "${TEAM_NAME}" --config "${WGCF_ACCOUNT_PATH}"
    if [ $? -ne 0 ] || [ ! -s "${WGCF_ACCOUNT_PATH}" ]; then
        error "Failed to register with Zero Trust. Please check your Team Name and browser authentication."
    fi

    info "Device registered successfully. Generating WireGuard profile..."
    wgcf generate --config "${WGCF_ACCOUNT_PATH}" --profile "${WGCF_PROFILE_PATH}"
    if [ ! -s "${WGCF_PROFILE_PATH}" ]; then
        error "Failed to generate WireGuard profile from the account data."
    fi

    info "Successfully fetched official Zero Trust configuration!"
}

patch_fscarmen_files() {
    info "Parsing the clean WireGuard profile..."
    
    # Extract clean data from the wgcf-profile.conf
    local WGCF_PrivateKey=$(grep -oP 'PrivateKey = \K.*' "${WGCF_PROFILE_PATH}")
    local WGCF_AddressV4=$(grep 'Address = 172' "${WGCF_PROFILE_PATH}" | grep -oP 'Address = \K.*')
    local WGCF_AddressV6=$(grep 'Address = 2606' "${WGCF_PROFILE_PATH}" | grep -oP 'Address = \K.*')
    local WGCF_Endpoint=$(grep -oP 'Endpoint = \K.*' "${WGCF_PROFILE_PATH}")
    local WGCF_PublicKey=$(grep -oP 'PublicKey = \K.*' "${WGCF_PROFILE_PATH}")

    if [ -z "$WGCF_PrivateKey" ] || [ -z "$WGCF_AddressV6" ]; then
        error "Failed to parse essential data from '${WGCF_PROFILE_PATH}'. The file might be corrupted."
    fi
    
    info "Applying patch to fscarmen's configuration files..."

    # Patch 1: Fix warp.conf (for wg-quick global mode)
    if [ -f "${FSCARMEN_WARP_CONF}" ]; then
        sed -i "s#^PrivateKey = .*#PrivateKey = ${WGCF_PrivateKey}#" "${FSCARMEN_WARP_CONF}"
        sed -i "s#^Address = 172.*#Address = ${WGCF_AddressV4}#" "${FSCARMEN_WARP_CONF}"
        sed -i "s#^Address = 2606.*#Address = ${WGCF_AddressV6}#" "${FSCARMEN_WARP_CONF}"
        sed -i "s#^Endpoint = .*#Endpoint = ${WGCF_Endpoint}#" "${FSCARMEN_WARP_CONF}"
        info "'${FSCARMEN_WARP_CONF}' has been patched."
    else
        warn "'${FSCARMEN_WARP_CONF}' not found, skipping."
    fi

    # Patch 2: Fix proxy.conf (for wireproxy SOCKS5 mode)
    if [ -f "${FSCARMEN_PROXY_CONF}" ]; then
        sed -i "s#^PrivateKey = .*#PrivateKey = ${WGCF_PrivateKey}#" "${FSCARMEN_PROXY_CONF}"
        sed -i "s#^Address = 172.*#Address = ${WGCF_AddressV4}#" "${FSCARMEN_PROXY_CONF}"
        sed -i "s#^Address = 2606.*#Address = ${WGCF_AddressV6}#" "${FSCARMEN_PROXY_CONF}"
        sed -i "s#^Endpoint = .*#Endpoint = ${WGCF_Endpoint}#" "${FSCARMEN_PROXY_CONF}"
        info "'${FSCARMEN_PROXY_CONF}' has been patched."
    else
        warn "'${FSCARMEN_PROXY_CONF}' not found, skipping."
    fi

    # Patch 3: Fix warp-account.conf (the JSON database)
    if [ -f "${FSCARMEN_ACCOUNT_DB}" ]; then
        # This is a more complex operation, we'll use jq for robustness
        local temp_json
        temp_json=$(mktemp)
        
        jq --arg pk "$WGCF_PrivateKey" \
           --arg v4 "$WGCF_AddressV4" \
           --arg v6 "$WGCF_AddressV6" \
           --arg ep "$WGCF_Endpoint" \
           '.private_key = $pk | .config.interface.addresses.v4 = ($v4 | sub("/32$"; "")) | .config.interface.addresses.v6 = ($v6 | sub("/128$"; "")) | .config.peers[0].endpoint.host = $ep' \
           "${FSCARMEN_ACCOUNT_DB}" > "${temp_json}" && mv "${temp_json}" "${FSCARMEN_ACCOUNT_DB}"

        info "'${FSCARMEN_ACCOUNT_DB}' has been patched."
    else
        warn "'${FSCARMEN_ACCOUNT_DB}' not found, skipping."
    fi

    info "All configuration files have been successfully patched!"
}

restart_services() {
    info "Attempting to restart WARP services to apply the new configuration..."
    local is_restarted=false
    
    if systemctl list-units --full -all | grep -q 'wireproxy.service'; then
        if systemctl is-active --quiet wireproxy.service; then
            info "Restarting wireproxy.service..."
            systemctl restart wireproxy.service
            is_restarted=true
        fi
    fi
    
    if systemctl list-units --full -all | grep -q 'wg-quick@warp.service'; then
        if systemctl is-active --quiet wg-quick@warp.service; then
            info "Restarting wg-quick@warp.service..."
            systemctl restart wg-quick@warp.service
            is_restarted=true
        fi
    fi

    if [ "$is_restarted" = false ]; then
        warn "No active WARP service (wireproxy or wg-quick) found to restart."
        warn "Please run 'warp o' or 'warp y' via fscarmen script to start the service with the new configuration."
    else
        info "Services restarted."
    fi
}

# --- Main Script Logic ---

main() {
    clear
    echo "================================================================="
    echo "  wgt-patch.sh - fscarmen WARP Zero Trust Account Fix Patch"
    echo "  Version: ${SCRIPT_VERSION}"
    echo "================================================================="
    echo
    
    check_root
    check_fscarmen
    
    echo
    warn "This script will guide you to fetch official Zero Trust account"
    warn "configuration and apply it to your existing fscarmen installation."
    echo
    pause_for_user
    
    prepare_environment
    get_zero_trust_config
    patch_fscarmen_files
    restart_services
    
    echo
    info "================================================================="
    info " Patch process completed successfully!"
    info " Your fscarmen installation is now using the official"
    info " Zero Trust configuration. Please test your connection."
    echo "================================================================="
}

# --- Entrypoint ---
main