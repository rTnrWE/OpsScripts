#!/bin/bash
#
# find_cf_ips.sh | v1.0.9
#
# Run Command (macOS/Linux/Windows):
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/find_cf_ips/find_cf_ips.sh)"
#

#=================================================
#               CONFIGURATION
#=================================================
SCRIPT_VERSION="1.0.9"
DEFAULT_LATENCY=100      # 默认延迟阈值 (ms)
PING_COUNT=5             # Ping次数
DEFAULT_C_FAIL_TOLERANCE=3 # 默认C段连续失败容忍度
C_SEARCH_RANGE=25        # C段探测范围
B_SEARCH_RANGE=10        # B段探测范围
B_FAIL_TOLERANCE=2       # B段连续失败容忍度 (保持固定)

#=================================================
#                  COLORS (Simplified)
#=================================================
GREEN='\033[0;32m'
RED='\033[0;31m'
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
        # BUG FIX: Force English output for ping on Windows to ensure consistent parsing, regardless of system language.
        ping_output=$(LANG=C ping -n $PING_COUNT -w 1000 "$ip" 2>/dev/null)
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
    local a=$1 b=$2 start_c=$3 direction=$4 max_latency=$5 c_fail_tolerance=$6
    local failure_counter=0
    local found_ranges=()

    for i in $(seq 1 $C_SEARCH_RANGE); do
        c_current=$((start_c + i * direction))
        
        if [ $c_current -lt 0 ] || [ $c_current -gt 255 ]; then break; fi

        random_d=$(( (RANDOM % 254) + 1 ))
        target_ip="${a}.${b}.${c_current}.${random_d}"
        
        echo "探测C段: ${target_ip}" >&2
        latency=$(check_latency "$target_ip")
        
        is_good=$(awk -v lat="$latency" -v max="$max_latency" 'BEGIN { print (lat > 0 && lat < max) }')

        if [[ "$is_good" -eq 1 ]]; then
            echo -e "  -> ${GREEN}发现可用段: ${a}.${b}.${c_current}.x (平均延迟: ${latency}ms)${NC}\n" >&2
            found_ranges+=("${a}.${b}.${c_current}.x")
            failure_counter=0
        else
            if [[ "$latency" == "9999" ]]; then
                echo -e "  -> ${RED}该段不通或请求超时.${NC}\n" >&2
            else
                echo -e "  -> ${RED}该段延迟过高 (平均延迟: ${latency}ms)${NC}\n" >&2
            fi
            
            ((failure_counter++))
            if [ $failure_counter -ge $c_fail_tolerance ]; then
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

# --- USER-FRIENDLY LOOP TO GET A VALID AND REACHABLE BASE IP ---
while true; do
    read -p "请输入一个基准IP地址 (直接回车退出): " start_ip
    
    if [[ -z "$start_ip" ]]; then
        echo "用户选择退出。" >&2
        exit 0
    fi

    if [[ ! $start_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo -e "${RED}错误: IP地址格式不正确，请重新输入。${NC}\n" >&2
        continue
    fi

    echo "正在测试基准IP..." >&2
    initial_latency=$(check_latency "$start_ip")

    if [[ "$initial_latency" != "9999" ]]; then
        echo -e "基准IP ${start_ip} 的平均延迟为: ${GREEN}${initial_latency}ms${NC}\n" >&2
        break
    else
        echo -e "${RED}错误: 基准IP ${start_ip} 无法访问或请求超时。${NC}\n" >&2
    fi
done

read -p "请输入探测延迟阈值 (默认 ${DEFAULT_LATENCY}ms): " MAX_LATENCY
: "${MAX_LATENCY:=${DEFAULT_LATENCY}}"
if ! [[ "$MAX_LATENCY" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}错误: 延迟阈值必须是数字!${NC}" >&2
    exit 1
fi

read -p "请输入连续失败容忍次数 (1-10, 默认 ${DEFAULT_C_FAIL_TOLERANCE}): " C_FAIL_TOLERANCE
: "${C_FAIL_TOLERANCE:=${DEFAULT_C_FAIL_TOLERANCE}}"
if ! [[ "$C_FAIL_TOLERANCE" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}错误: 输入必须是数字!${NC}" >&2
    exit 1
fi

IFS='.' read -r A B_START C_START D <<< "$start_ip"

echo "---------------------------------------------------" >&2
echo "基准IP: $start_ip" >&2
echo "延迟阈值: ${MAX_LATENCY}ms" >&2
echo "连续失败容忍: ${C_FAIL_TOLERANCE}次" >&2
echo "---------------------------------------------------" >&2

ALL_GOOD_RANGES=()
ALL_GOOD_RANGES+=("${A}.${B_START}.${C_START}.x") 

echo -e "\n--- Phase 1: 开始探测 ${A}.${B_START}.x.x ---" >&2
down_c_results=($(probe_c_segments $A $B_START $C_START -1 $MAX_LATENCY $C_FAIL_TOLERANCE))
up_c_results=($(probe_c_segments $A $B_START $C_START 1 $MAX_LATENCY $C_FAIL_TOLERANCE))
ALL_GOOD_RANGES+=("${down_c_results[@]}" "${up_c_results[@]}")

echo -e "\n--- Phase 2: 开始探测相邻B段 ---" >&2
for direction in -1 1; do
    b_failure_counter=0
    direction_text=$([[ $direction -eq 1 ]] && echo "向上" || echo "向下")

    for i in $(seq 1 $B_SEARCH_RANGE); do
        b_current=$((B_START + i * direction))
        if [ $b_current -lt 0 ] || [ $b_current -gt 255 ]; then break; fi
        
        echo -e "\n尝试B段: ${A}.${b_current}.x.x" >&2
        
        foothold_found=false
        for c_foothold in 128 64 192 1; do
            random_d=$(( (RANDOM % 254) + 1 ))
            target_ip="${A}.${b_current}.${c_foothold}.${random_d}"
            latency=$(check_latency "$target_ip")
            is_good=$(awk -v lat="$latency" -v max="$MAX_LATENCY" 'BEGIN { print (lat > 0 && lat < max) }')
            
            if [[ "$is_good" -eq 1 ]]; then
                echo -e "  -> ${GREEN}在 ${A}.${b_current}.x.x 发现存活点, 开始全面扫描...${NC}" >&2
                ALL_GOOD_RANGES+=("${A}.${b_current}.${c_foothold}.x")
                down_c_results=($(probe_c_segments $A $b_current $c_foothold -1 $MAX_LATENCY $C_FAIL_TOLERANCE))
                up_c_results=($(probe_c_segments $A $b_current $c_foothold 1 $MAX_LATENCY $C_FAIL_TOLERANCE))
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
