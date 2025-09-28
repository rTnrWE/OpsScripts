sudo bash -s <<'EOF'
#!/bin/bash
# 脚本出错时立即退出
set -e

# --- 配置目标DNS ---
TARGET_DNS="8.8.8.8 1.1.1.1"
# --------------------

# 定义颜色输出
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m" # No Color

# 1. 权限检查
if [[ $EUID -ne 0 ]]; then
   echo -e "${YELLOW}错误: 此脚本必须以 root 用户身份运行。${NC}" 
   exit 1
fi

# 2. 安装检查
if ! command -v resolvectl &> /dev/null; then
    echo -e "${YELLOW}--> 检测到 systemd-resolved 未安装，正在自动安装...${NC}"
    apt-get update -y > /dev/null
    apt-get install -y systemd-resolved > /dev/null
    systemctl enable --now systemd-resolved
    echo -e "${GREEN}--> ✅ systemd-resolved 安装并启动成功。${NC}"
else
    echo -e "${GREEN}--> systemd-resolved 已安装，继续执行检查。${NC}"
fi

# 3. 状态检查
# 获取当前的全局DNS服务器和搜索域
# 使用 sed 和 tr 来清理输出，确保比较的准确性
CURRENT_DNS=$(resolvectl status | grep -A2 'Global' | grep 'DNS Servers:' | sed 's/DNS Servers: //g' | tr -s ' ')
CURRENT_DOMAINS=$(resolvectl status | grep -A2 'Global' | grep 'DNS Domain:' | sed 's/DNS Domain: //g')

echo "--> 当前全局DNS: [$CURRENT_DNS]"
echo "--> 当前搜索域: [$CURRENT_DOMAINS]"

# 比较当前配置和目标配置
if [[ "$CURRENT_DNS" == "$TARGET_DNS" ]] && [[ -z "$CURRENT_DOMAINS" ]]; then
    echo -e "\n${GREEN}✅ DNS 已是最新配置，无需修改。${NC}"
    exit 0
fi

# 4. 执行修改
echo -e "\n${YELLOW}--> DNS 配置不匹配，开始执行修改...${NC}"
echo -e "[Resolve]\nDNS=${TARGET_DNS}\nDomains=" > /etc/systemd/resolved.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl restart systemd-resolved
sleep 1
echo -e "${GREEN}--> ✅ DNS 配置修改并重启服务成功。${NC}"

# 5. 最终验证
echo -e "\n${GREEN}✅ 全部操作完成！以下是更新后的 DNS 状态：${NC}"
echo "----------------------------------------------------"
resolvectl status
EOF
