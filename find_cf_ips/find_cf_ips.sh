#!/bin/bash
#
# find_cf_ips.sh | v1.0.2
# run: bash -c "$(curl -fsSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/find_cf_ips/find_cf_ips.sh)"
#

#=================================================
#               CONFIGURATION
#=================================================
SCRIPT_VERSION="1.0.2"
DEFAULT_LATENCY=100      # 默认延迟阈值 (ms)
PING_COUNT=5             # Ping次数
C_SEARCH_RANGE=25        # C段探测范围
B_SEARCH_RANGE=10        # B段探测范围
C_FAIL_TOLERANCE=3       # C段连续失败容忍度
B_FAIL_TOLERANCE=2       # B段连续失败容忍度

#=================================================
#                  COLORS
#=================================================
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#=================================================
#               HELPER FUNCTIONS
#=================================================

check_latency() {
    local ip=$1
    local os_type=$(uname)
    local result
    local ping_output

    if [[ "$os_type" == "Linux" ]]; then
        ping_output=$(ping -c $PING_COUNT -W 1 -i 0.2 "$ip" 2>/dev/null)
    elif [[ "$os_type" == "Darwin" ]]; then # macOS
        ping_output=$(ping -c $PING_COUNT -t 5 "$ip" 2>/dev/null)
    else # Git Bash on Windows
        ping_output=$(ping -n $PING_COUNT -w 1000 "$ip" 2>/dev/null)
    fi

    if [[ $? -ne 0 ]]; then
        echo "9999"
        return
    fi

    if [[ "$os_type" == "Linux" || "$os_type" == "Darwin" ]]; then
        result=$(echo "$ping_output" | tail -1 | awk -F'/' '{print $5}')
    else
        result=$(echo "$ping_output" | grep 'Average' | awk -F'=' '{print $4}' | sed 's/ms//g' | tr -d ' ')
    fi
    
    if ! [[ "$result" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "9999"
    else
        echo "$result"
    fi
}

probe_c_segments() {
    local a=$1 b=$2 start_c=$3 direction=$4 max_latency=$5
    local failure_counter=0
    local found_ranges=()

    for i in $(seq 1 $C_SEARCH_RANGE); do
        c_current=$((start_c + i * direction))
        
        if [ $c_current -lt 0 ] || [ $c_current -gt 255 ]; then break; fi

        random_d=$(( (RANDOM % 254) + 1 ))
        target_ip="${a}.${b}.${c_current}.${random_d}"
        
        echo -e "${YELLOW}探测C段: ${target_ip}${NC}" >&2
        latency=$(check_latency "$target_ip")
        
        is_good=$(awk -v lat="$latency" -v max="$max_latency" 'BEGIN { print (lat > 0 && lat < max) }')

        if [[ "$is_good" -eq 1 ]]; then
            echo -e "  -> ${GREEN}发现可用段: ${a}.${b}.${c_current}.x (延迟: ${latency}ms)${NC}\n" >&2
            found_ranges+=("${a}.${b}.${c_current}.x")
            failure_counter=0
        else
            echo -e "  -> ${RED}该段不佳或超时 (延迟: ${latency}ms)${NC}\n" >&2
            ((failure_counter++))
            if [ $failure_counter -ge $C_FAIL_TOLERANCE ]; then
                echo -e "${RED}已连续失败 ${failure_counter} 次, 停止该方向探测.${NC}" >&2
                break
            fi
        fi
    done
    echo "${found_ranges[@]}"
}

#=================================================
#                  MAIN SCRIPT
#=================================================
clear
echo "===================================================" >&2
echo "  相邻IP段探测工具 (v${SCRIPT_VERSION})" >&2
echo "===================================================" >&2

read -p "请输入一个基准IP地址: " start_ip
if [[ ! $start_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo -e "${RED}错误: IP地址格式不正确!${NC}" >&2
  exit 1
fi

read -p "请输入延迟阈值 (默认 ${DEFAULT_LATENCY}ms): " MAX_LATENCY
: "${MAX_LATENCY:=${DEFAULT_LATENCY}}"
if ! [[ "$MAX_LATENCY" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}错误: 延迟阈值必须是数字!${NC}" >&2
    exit 1
fi

IFS='.' read -r A B_START C_START D <<< "$start_ip"

echo "---------------------------------------------------" >&2
echo "基准IP: $start_ip" >&2
echo "延迟阈值: ${MAX_LATENCY}ms" >&2
echo "---------------------------------------------------" >&2

ALL_GOOD_RANGES=()
ALL_GOOD_RANGES+=("${A}.${B_START}.${C_START}.x") 

# --- Phase 1: Probe C-segments in current B-segment ---
echo -e "\n${BLUE}--- Phase 1: 开始探测 ${A}.${B_START}.x.x ---${NC}" >&2
down_c_results=($(probe_c_segments $A $B_START $C_START -1 $MAX_LATENCY))
up_c_results=($(probe_c_segments $A $B_START $C_START 1 $MAX_LATENCY))
ALL_GOOD_RANGES+=("${down_c_results[@]}" "${up_c_results[@]}")

# --- Phase 2: Probe adjacent B-segments ---
echo -e "\n${BLUE}--- Phase 2: 开始探测相邻B段 ---${NC}" >&2
for direction in -1 1; do
    b_failure_counter=0
    direction_text=$([[ $direction -eq 1 ]] && echo "向上" || echo "向下")

    for i in $(seq 1 $B_SEARCH_RANGE); do
        b_current=$((B_START + i * direction))
        if [ $b_current -lt 0 ] || [ $b_current -gt 255 ]; then break; fi
        
        echo -e "\n${YELLOW}尝试B段: ${A}.${b_current}.x.x${NC}" >&2
        
        foothold_found=false
        for c_foothold in 128 64 192 1; do
            random_d=$(( (RANDOM % 254) + 1 ))
            target_ip="${A}.${b_current}.${c_foothold}.${random_d}"
            latency=$(check_latency "$target_ip")
            is_good=$(awk -v lat="$latency" -v max="$MAX_LATENCY" 'BEGIN { print (lat > 0 && lat < max) }')
            
            if [[ "$is_good" -eq 1 ]]; then
                echo -e "${GREEN}在 ${A}.${b_current}.x.x 发现存活点, 开始全面扫描...${NC}" >&2
                ALL_GOOD_RANGES+=("${A}.${b_current}.${c_foothold}.x")
                down_c_results=($(probe_c_segments $A $b_current $c_foothold -1 $MAX_LATENCY))
                up_c_results=($(probe_c_segments $A $b_current $c_foothold 1 $MAX_LATENCY))
                ALL_GOOD_RANGES+=("${down_c_results[@]}" "${up_c_results[@]}")
                foothold_found=true
                break 
            fi
        done

        if [ "$foothold_found" = true ]; then
            b_failure_counter=0
        else
            echo -e "${RED}B段 ${A}.${b_current}.x.x 未发现存活点.${NC}" >&2
            ((b_failure_counter++))
            if [ $b_failure_counter -ge $B_FAIL_TOLERANCE ]; then
                echo -e "${RED}已连续 ${b_failure_counter} 个B段探测失败, 停止${direction_text}探测.${NC}" >&2
                break
            fi
        fi
    done
done

# --- FINAL RESULTS ---
echo "" 
echo "==================================================="
echo -e "${GREEN}探测完成！发现以下可用IP段:${NC}"
IFS=$'\n' sorted_ranges=($(sort -t . -k 2,2n -k 3,3n -u <<<"${ALL_GOOD_RANGES[*]}"))
unset IFS

if [ ${#sorted_ranges[@]} -eq 0 ]; then
    echo -e "${RED}未发现任何满足条件的IP段。${NC}"
else
    for range in "${sorted_ranges[@]}"; do
        echo "$range"
    done
fi
echo "==================================================="
