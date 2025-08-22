#!/bin/bash

#===================================================================
#
#          FILE:  bt_purify.sh
#
#         USAGE:  bash bt_purify.sh
#
#   DESCRIPTION:  宝塔面板净化脚本
#                 - 移除面板部分非必要功能，使其更纯净、轻量。
#
#       OPTIONS:  ---
#
#  REQUIREMENTS:  Debian/Ubuntu
#          BUGS:  ---
#         NOTES:  ---
#        AUTHOR:  Gemini & Your Collaboration
#       VERSION:  1.0
#       CREATED:  2025-08-21
#      REVISION:  v1.1 (Wording Optimized & Line Endings Fixed)
#
#===================================================================

# 字体颜色
Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Green_background_prefix="\033[42;37m"
Red_background_prefix="\033[41;37m"
Font_color_suffix="\033[0m"

# 提示信息
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Green_font_prefix}[注意]${Font_color_suffix}"

# 宝塔面板核心文件路径
PANEL_PATH="/www/server/panel"
INIT_PY_FILE="${PANEL_PATH}/BTPanel/__init__.py"
PUBLIC_PY_FILE="${PANEL_PATH}/class/public.py"

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${Error} 当前非ROOT账号(或没有ROOT权限)，无法继续操作，请使用${Green_background_prefix} sudo -i ${Font_color_suffix}命令获取临时ROOT权限（执行后会提示输入当前账号的密码）。"
        exit 1
    fi
}

# 检查宝塔面板是否安装
check_bt_panel() {
    if [ ! -d "${PANEL_PATH}" ]; then
        echo -e "${Error} 宝塔面板未安装，请先安装！"
        exit 1
    fi
}

# 备份文件
backup_file() {
    local file_path=$1
    local bak_file_path="${file_path}.bak"
    if [ -f "${bak_file_path}" ]; then
        echo -e "${Info} ${file_path} 的备份文件已存在，跳过备份。"
    else
        if [ -f "${file_path}" ]; then
            cp "${file_path}" "${bak_file_path}"
            echo -e "${Info} 已成功备份 ${file_path} 到 ${bak_file_path}"
        else
            echo -e "${Error} 文件 ${file_path} 不存在，无法备份！"
            return 1
        fi
    fi
    return 0
}

# 恢复文件
restore_file() {
    local file_path=$1
    local bak_file_path="${file_path}.bak"
    if [ -f "${bak_file_path}" ]; then
        \cp "${bak_file_path}" "${file_path}"
        echo -e "${Info} 已从备份恢复 ${file_path}"
    else
        echo -e "${Error} 备份文件 ${bak_file_path} 不存在，无法恢复！"
    fi
}

# 优化 1: 停止写入请求日志 (request 日志)
perform_op_1() {
    echo -e "\n${Green_font_prefix}>>> 开始执行 [优化 1]: 停止写入面板请求日志 (request 日志)...${Font_color_suffix}"
    backup_file "${INIT_PY_FILE}" || return
    
    # 检查是否已经修改过
    if grep -q "# public.write_request_log(reques)" "${INIT_PY_FILE}"; then
        echo -e "${Info} 检测到日志写入功能已被禁用，无需重复操作。"
        return
    fi

    sed -i 's/public.write_request_log(reques)/# public.write_request_log(reques)/g' "${INIT_PY_FILE}"
    
    if grep -q "# public.write_request_log(reques)" "${INIT_PY_FILE}"; then
        echo -e "${Info} [优化 1] 成功完成！"
    else
        echo -e "${Error} [优化 1] 失败！请检查文件权限或手动修改。"
    fi
}

# 优化 2: 去除面板日志与信息上报
perform_op_2() {
    echo -e "\n${Green_font_prefix}>>> 开始执行 [优化 2]: 去除面板错误日志与信息上报...${Font_color_suffix}"
    backup_file "${INIT_PY_FILE}" || return

    # 检查并禁用错误上报
    if grep -q "# public.run_thread(public.httpPost" "${INIT_PY_FILE}"; then
        echo -e "${Info} 检测到错误上报功能已被禁用，跳过。"
    else
        sed -i 's/public.run_thread(public.httpPost, ("https:\/\/api.bt.cn\/bt_error\/index.php", error_infos))/# public.run_thread(public.httpPost, ("https:\/\/api.bt.cn\/bt_error\/index.php", error_infos))/g' "${INIT_PY_FILE}"
        if grep -q "# public.run_thread(public.httpPost" "${INIT_PY_FILE}"; then
            echo -e "${Info} 错误上报功能已禁用。"
        else
            echo -e "${Error} 禁用错误上报失败！"
        fi
    fi

    # 检查并禁用定时检查/上报
    if grep -q "# public.run_thread(public.ExecShell, ('btpython /www/server/panel/script/reload_check.py hour',))" "${INIT_PY_FILE}"; then
        echo -e "${Info} 检测到定时检查/上报功能已被禁用，跳过。"
    else
        sed -i "s/public.run_thread(public.ExecShell, ('btpython \/www\/server\/panel\/script\/reload_check.py hour',))/# public.run_thread(public.ExecShell, ('btpython \/www\/server\/panel\/script\/reload_check.py hour',))/g" "${INIT_PY_FILE}"
        if grep -q "# public.run_thread(public.ExecShell, ('btpython /www/server/panel/script/reload_check.py hour',))" "${INIT_PY_FILE}"; then
            echo -e "${Info} 定时检查/上报功能已禁用。"
        else
            echo -e "${Error} 禁用定时检查/上报失败！"
        fi
    fi
     echo -e "${Info} [优化 2] 执行完毕。"
}

# 优化 3: 关闭活动推荐与在线客服
perform_op_3() {
    echo -e "\n${Green_font_prefix}>>> 开始执行 [优化 3]: 关闭活动推荐与在线客服...${Font_color_suffix}"
    backup_file "${INIT_PY_FILE}" || return

    if grep -q "data\['show_recommend'\] = False" "${INIT_PY_FILE}"; then
        echo -e "${Info} 检测到活动推荐与在线客服已被关闭，无需重复操作。"
    else
        sed -i "s/data\['show_recommend'\] = not os.path.exists('data\/not_recommend.pl')/data['show_recommend'] = False/g" "${INIT_PY_FILE}"
        sed -i "s/data\['show_workorder'\] = not os.path.exists('data\/not_workorder.pl')/data['show_workorder'] = False/g" "${INIT_PY_FILE}"
        if grep -q "data\['show_recommend'\] = False" "${INIT_PY_FILE}"; then
            echo -e "${Info} [优化 3] 成功完成！"
        else
            echo -e "${Error} [优化 3] 失败！"
        fi
    fi
}

# 显示主菜单
main_menu() {
    while true; do
        clear
        echo "================================================================"
        echo "                  宝塔面板净化脚本 v1.0"
        echo "================================================================"
        echo ""
        echo "  1. 执行所有净化选项 (推荐)"
        echo "  --------------------------------------------------"
        echo "  2. [优化 1] 停止写入面板请求日志 (request 日志)"
        echo "  3. [优化 2] 去除面板错误日志与信息上报"
        echo "  4. [优化 3] 关闭活动推荐与在线客服"
        echo "  --------------------------------------------------"
        echo "  5. 恢复所有文件从备份"
        echo "  6. 仅重启宝塔面板"
        echo "  0. 退出脚本"
        echo ""
        read -p "请输入数字 [0-6]: " choice

        case $choice in
            1)
                perform_op_1
                perform_op_2
                perform_op_3
                echo -e "\n${Tip} 所有净化选项已执行完毕。建议重启面板使所有设置生效。"
                read -p "按任意键返回主菜单..."
                ;;
            2)
                perform_op_1
                read -p "操作已执行完毕，按任意键返回主菜单..."
                ;;
            3)
                perform_op_2
                read -p "操作已执行完毕，按任意键返回主菜单..."
                ;;
            4)
                perform_op_3
                read -p "操作已执行完毕，按任意键返回主菜单..."
                ;;
            5)
                restore_file "${INIT_PY_FILE}"
                echo -e "\n${Tip} 恢复操作已执行完毕。建议重启面板以应用原始文件。"
                read -p "按任意键返回主菜单..."
                ;;
            6)
                echo -e "\n${Info} 正在重启宝塔面板，请稍候..."
                bt restart
                echo -e "${Info} 宝塔面板重启命令已发送。"
                read -p "按任意键返回主菜单..."
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${Error} 无效输入，请重新输入！"
                sleep 2
                ;;
        esac
    done
}

# 主程序入口
check_root
check_bt_panel

# 检查 sed 是否可用
if ! command -v sed &> /dev/null; then
    echo -e "${Error} sed 命令未找到，脚本无法运行。请先安装 sed。"
    exit 1
fi

main_menu
