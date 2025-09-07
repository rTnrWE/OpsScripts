#!/bin/bash

#================================================================================
# FILE:         sbv.sh
# USAGE:        First time: bash <(curl -fsSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbv.sh)
#               After install, run: bash /usr/local/bin/sbv.sh
# DESCRIPTION:  A dedicated management platform for Sing-Box (VLESS+Reality+Vision).
# REVISION:     2.8
#================================================================================

SCRIPT_VERSION="2.8"
SCRIPT_URL="https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/Sing-Box-VRV/sbv.sh"
INSTALL_PATH="/usr/local/bin/sbv.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
CONFIG_PATH="/etc/sing-box/config.json"
INFO_PATH="/etc/sing-box/vrv_info.env"
SINGBOX_BINARY=""

check_root() { [[ "$EUID" -ne 0 ]] && { echo -e "${RED}Error: This script must be run as root.${NC}"; exit 1; }; }

check_dependencies() {
    for cmd in curl jq openssl; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${YELLOW}Dependency '$cmd' not found, attempting to install...${NC}"
            if command -v apt-get &> /dev/null; then apt-get update >/dev/null && apt-get install -y $cmd
            elif command -v yum &> /dev/null; then yum install -y $cmd
            elif command -v dnf &> /dev/null; then dnf install -y $cmd
            else echo -e "${RED}Cannot determine package manager. Please install '$cmd' manually.${NC}"; exit 1; fi
            if ! command -v $cmd &> /dev/null; then echo -e "${RED}Failed to install '$cmd'.${NC}"; exit 1; fi
        fi
    done
}

install_singbox_core() {
    echo -e "${BLUE}>>> Installing/Updating sing-box latest stable version...${NC}"
    if ! bash <(curl -fsSL https://sing-box.app/deb-install.sh); then echo -e "${RED}sing-box core installation failed.${NC}"; return 1; fi
    SINGBOX_BINARY=$(command -v sing-box)
    if [[ -z "$SINGBOX_BINARY" ]]; then echo -e "${RED}Error: sing-box executable not found after installation.${NC}"; return 1; fi
    echo -e "${GREEN}sing-box core installed successfully. Version: $($SINGBOX_BINARY version | head -n 1)${NC}"
}

internal_validate_domain() {
    local domain="$1"
    echo -n -e "${YELLOW}Validating ${domain} ... ${NC}"
    if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 5 "https://${domain}" 2>&1 | grep -q "SSL connection using TLSv1.3"; then
        echo -e "${GREEN}Success!${NC}"; return 0
    else
        echo -e "${RED}Failed!${NC}"; return 1
    fi
}

generate_config() {
    echo -e "${BLUE}>>> Configuring VLESS + Reality + Vision...${NC}"
    local handshake_server
    while true; do
        read -p "Enter Reality domain [default: www.microsoft.com]: " handshake_server
        handshake_server=${handshake_server:-www.microsoft.com}
        internal_validate_domain "$handshake_server" && break
        read -p "Retry, [F]orce use, or [A]bort? (R/F/A): " choice
        case "${choice,,}" in
            f|force) echo -e "${YELLOW}Warning: Forcing to use unverified domain.${NC}"; break ;;
            a|abort) echo -e "${RED}Installation aborted.${NC}"; return 1 ;;
        esac
    done

    echo -e "${YELLOW}Generating keys and IDs...${NC}"
    local key_pair=$($SINGBOX_BINARY generate reality-keypair)
    local private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    local public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    local uuid=$($SINGBOX_BINARY generate uuid)
    local short_id=$(openssl rand -hex 8)
    mkdir -p /etc/sing-box

    tee "$CONFIG_PATH" > /dev/null <<EOF
{ "log": { "disabled": true }, "inbounds": [ { "type": "vless", "tag": "vless-in", "listen": "::", "listen_port": 443, "sniff": true, "sniff_override_destination": true, "users": [ { "uuid": "${uuid}", "flow": "xtls-rprx-vision" } ], "tls": { "enabled": true, "server_name": "${handshake_server}", "reality": { "enabled": true, "handshake": { "server": "${handshake_server}", "server_port": 443 }, "private_key": "${private_key}", "short_id": [ "${short_id}" ] } } } ], "outbounds": [ { "type": "direct", "tag": "direct" } ] }
EOF
    tee "$INFO_PATH" > /dev/null <<EOF
UUID=${uuid}
PUBLIC_KEY=${public_key}
SHORT_ID=${short_id}
HANDSHAKE_SERVER=${handshake_server}
LISTEN_PORT=443
EOF
    echo -e "${GREEN}Configuration file and info saved.${NC}"
}

start_service() {
    echo -e "${BLUE}>>> Starting and enabling sing-box service...${NC}"
    systemctl daemon-reload; systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
    if systemctl is-active --quiet sing-box; then echo -e "${GREEN}sing-box service started successfully.${NC}"; else echo -e "${RED}Error: Failed to start sing-box service.${NC}"; return 1; fi
}

show_client_config_format() {
    if [[ ! -f "$INFO_PATH" ]]; then return; fi
    source "$INFO_PATH"
    local server_ip=$(curl -s4 icanhazip.com || curl -s6 icanhazip.com) || server_ip="[YOUR_SERVER_IP]"
    
    echo -e "--------------------------------------------------"
    echo -e "${GREEN}Client Manual Configuration:${NC}"
    printf "  %-14s: ${BLUE}%s${NC}\n" "server" "$server_ip"
    printf "  %-14s: ${BLUE}%s${NC}\n" "port" "$LISTEN_PORT"
    printf "  %-14s: ${BLUE}%s${NC}\n" "uuid" "$UUID"
    printf "  %-14s: ${BLUE}%s${NC}\n" "servername" "$HANDSHAKE_SERVER"
    printf "  %-14s: ${BLUE}%s${NC}\n" "public-key" "$PUBLIC_KEY"
    printf "  %-14s: ${BLUE}%s${NC}\n" "short-id" "$SHORT_ID"
    echo -e "--------------------------------------------------"
}

show_summary() {
    if [[ ! -f "$INFO_PATH" ]]; then echo -e "${RED}Error: Configuration info file not found.${NC}"; return; fi
    source "$INFO_PATH"
    local server_ip=$(curl -s4 icanhazip.com || curl -s6 icanhazip.com) || server_ip="[YOUR_SERVER_IP]"
    local vless_link="vless://${UUID}@${server_ip}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${HANDSHAKE_SERVER}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Sing-Box-VRV"

    echo -e "\n=================================================="
    echo -e "${GREEN}       Sing-Box-VRV (VLESS+Reality) Config       ${NC}"
    echo -e "=================================================="
    printf "  %-22s: ${BLUE}%s${NC}\n" "Server Config File" "$CONFIG_PATH"
    echo -e "--------------------------------------------------"
    echo -e "${GREEN}VLESS Import Link:${NC}"
    echo -e "${BLUE}${vless_link}${NC}"
    
    show_client_config_format
}

install_vrv() {
    echo -e "${BLUE}--- Starting Sing-Box-VRV Installation ---${NC}"
    install_singbox_core || return 1
    generate_config || return 1
    start_service || return 1
    show_summary
    echo -e "\n${GREEN}--- Sing-Box-VRV Installed Successfully ---${NC}"
}

change_reality_domain() {
    local new_domain
    while true; do
        read -p "Enter new Reality domain: " new_domain
        [[ -z "$new_domain" ]] && { echo -e "${RED}Domain cannot be empty.${NC}"; continue; }
        internal_validate_domain "$new_domain" && break
        read -p "Retry, [F]orce use, or [A]bort? (R/F/A): " choice
        case "${choice,,}" in
            f|force) echo -e "${YELLOW}Warning: Forcing to use unverified domain.${NC}"; break ;;
            a|abort) echo -e "${RED}Operation aborted.${NC}"; return ;;
        esac
    done

    echo -e "${BLUE}>>> Updating configuration file...${NC}"
    jq --arg domain "$new_domain" '.inbounds[0].tls.server_name = $domain | .inbounds[0].tls.reality.handshake.server = $domain' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    if [[ $? -ne 0 ]]; then echo -e "${RED}Error: Failed to update config file.${NC}"; return; fi

    sed -i "s/^HANDSHAKE_SERVER=.*/HANDSHAKE_SERVER=${new_domain}/" "$INFO_PATH"
    echo -e "${GREEN}Configuration file updated.${NC}"
    
    systemctl restart sing-box; sleep 1; echo -e "\n${BLUE}Service restarted. Here is your new configuration:${NC}"
    show_summary
}

manage_service() {
    disable_logs_and_restart() {
        echo -e "\n${YELLOW}>>> Disabling logs and restarting service...${NC}"
        jq '.log = {"disabled": true}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
        systemctl restart sing-box
        echo -e "${GREEN}Service restored to no-log mode.${NC}"
    }
    
    clear
    echo -e "${BLUE}--- sing-box Service Management ---${NC}"
    echo -e "-------------------------"
    echo -e " 1. Restart Service"
    echo -e " 2. Stop Service"
    echo -e " 3. Start Service"
    echo -e " 4. View Status"
    echo -e " 5. ${YELLOW}View Real-time Logs (On-demand)${NC}"
    echo -e " 0. Back to Main Menu"
    echo -e "-------------------------"
    read -p "Enter your choice: " sub_choice
    case $sub_choice in
        1) systemctl restart sing-box; echo -e "${GREEN}Service restarted.${NC}"; sleep 1 ;;
        2) systemctl stop sing-box; echo -e "${YELLOW}Service stopped.${NC}"; sleep 1 ;;
        3) systemctl start sing-box; echo -e "${GREEN}Service started.${NC}"; sleep 1 ;;
        4) systemctl status sing-box ;;
        5) 
            echo -e "\n${YELLOW}>>> Temporarily enabling logs...${NC}"
            jq '.log = {"level": "info", "timestamp": true}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            systemctl restart sing-box
            echo -e "${GREEN}Logs are now active. Displaying logs...${NC}"
            echo -e "${YELLOW}Press Ctrl+C to stop and automatically disable logging.${NC}"
            sleep 2
            trap disable_logs_and_restart SIGINT
            journalctl -u sing-box -f --no-pager
            disable_logs_and_restart
            trap - SIGINT
            ;;
        *) return ;;
    esac
}

uninstall_vrv() {
    read -p "$(echo -e ${RED}"WARNING: This will completely uninstall Sing-Box-VRV and this script. Are you sure? (y/N): "${NC})" confirm
    if [[ "${confirm,,}" != "y" ]]; then echo "Operation cancelled."; return; fi
    systemctl stop sing-box &>/dev/null; systemctl disable sing-box &>/dev/null
    local bin_path=$(command -v sing-box); rm -rf /etc/sing-box /etc/systemd/system/sing-box.service
    if [[ -n "$bin_path" ]]; then rm -f "$bin_path"; fi
    systemctl daemon-reload; rm -f "$INSTALL_PATH"
    echo -e "${GREEN}Sing-Box-VRV has been completely removed.${NC}"
}

update_script() {
    echo -e "${BLUE}>>> Checking for script updates...${NC}"
    local temp_script=$(mktemp)
    if ! curl -fsSL "$SCRIPT_URL" -o "$temp_script"; then echo -e "${RED}Failed to download new script version.${NC}"; rm "$temp_script"; return; fi
    if ! diff -q "$INSTALL_PATH" "$temp_script" &>/dev/null; then
        read -p "$(echo -e ${GREEN}"New version found. Update now? (y/N): "${NC})" confirm
        if [[ "${confirm,,}" == "y" ]]; then
            mv "$temp_script" "$INSTALL_PATH"; chmod +x "$INSTALL_PATH"; echo -e "${GREEN}Script updated! Reloading...${NC}"; exec "$INSTALL_PATH"
        fi
    else
        echo -e "${GREEN}You are already running the latest version.${NC}"; rm "$temp_script"
    fi
}

update_singbox_core() {
    install_singbox_core && systemctl restart sing-box && echo -e "${GREEN}sing-box core updated and restarted successfully.${NC}"
}

validate_reality_domain() {
    clear; echo -e "${BLUE}--- Reality Domain Stability Test ---${NC}"; read -p "Enter domain to test: " domain
    if [[ -z "$domain" ]]; then echo -e "\n${RED}Domain cannot be empty.${NC}"; return; fi
    echo -e "\n${YELLOW}Performing 5 TLSv1.3 connection tests...${NC}"; local success=0
    for i in {1..5}; do echo -n "Test $i/5: "; if curl -vI --tlsv1.3 --tls-max 1.3 --connect-timeout 10 "https://${domain}" 2>&1 | grep -q "SSL connection using TLSv1.3"; then echo -e "${GREEN}Success${NC}"; ((success++)); else echo -e "${RED}Failure${NC}"; fi; sleep 1; done
    echo "--------------------------------------------------"; if [[ $success -eq 5 ]]; then echo -e "${GREEN}Conclusion: Domain is highly suitable.${NC}"; elif [[ $success -gt 0 ]]; then echo -e "${YELLOW}Conclusion: Domain is usable but may be unstable.${NC}"; else echo -e "${RED}Conclusion: Domain is not suitable.${NC}"; fi;
}

main_menu() {
    clear
    echo -e "======================================================"
    echo -e "${GREEN}      Sing-Box-VRV Management Platform v${SCRIPT_VERSION}      ${NC}"
    echo -e "======================================================"
    if [[ ! -f "$CONFIG_PATH" ]]; then echo -e " 1. ${GREEN}Install Sing-Box-VRV${NC}"; else echo -e " 1. ${YELLOW}Re-install Sing-Box-VRV${NC}"; fi
    echo -e " 2. View Configuration"
    echo -e " 3. Change Reality Domain"
    echo -e " 4. Manage sing-box Service"
    echo -e " 5. ${YELLOW}Validate Reality Domain${NC}"
    echo -e "------------------------------------------------------"
    echo -e " 7. Update sing-box Core"
    echo -e " 8. ${BLUE}Update This Script${NC}"
    echo -e " 9. ${RED}Uninstall Everything${NC}"
    echo -e " 0. Exit"
    echo -e "======================================================"
    read -p "Enter your choice: " choice

    local is_installed=true
    if [[ ! -f "$CONFIG_PATH" && ",2,3,4,7," == *",${choice},"* ]]; then
        echo -e "\n${RED}Error: Please install Sing-Box-VRV first (Option 1).${NC}"; is_installed=false
    fi

    if [[ "$is_installed" == true ]]; then
        case "${choice,,}" in
            1) install_vrv ;;
            2) show_summary ;;
            3) change_reality_domain ;;
            4) manage_service ;;
            5) validate_reality_domain ;;
            7) update_singbox_core ;;
            8) if [[ -f "$INSTALL_PATH" ]]; then update_script; else echo -e "${RED}Script is not installed, cannot update.${NC}"; fi ;;
            9) uninstall_vrv; exit 0 ;;
            0) exit 0 ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
    fi
    read -n 1 -s -r -p "Press any key to return to the menu..."
    main_menu
}

# --- Script Entry Point ---
if [[ "$(realpath "$0")" != "$INSTALL_PATH" ]]; then
    clear
    echo -e "======================================================"
    echo -e "${GREEN}    Welcome to Sing-Box-VRV v${SCRIPT_VERSION} Platform    ${NC}"
    echo -e "======================================================"
    echo -e "This script will be installed to: ${BLUE}${INSTALL_PATH}${NC}"
    read -p "Press Enter to begin, or Ctrl+C to cancel..."
    
    mkdir -p "$(dirname "$INSTALL_PATH")"
    if ! cp -f "$(realpath "$0")" "$INSTALL_PATH"; then
        echo -e "${RED}Error: Failed to copy script to ${INSTALL_PATH}. Check permissions.${NC}"
        exit 1
    fi
    chmod +x "$INSTALL_PATH"
    
    echo -e "\n${GREEN}Management script installed successfully!${NC}"
    echo -e "From now on, you can run this platform anytime with the command:"
    echo -e "  ${BLUE}bash ${INSTALL_PATH}${NC}"
    echo -e "\n${YELLOW}Starting the management platform automatically...${NC}"
    sleep 3
    exec "$INSTALL_PATH"
else
    check_root
    check_dependencies
    main_menu
fi