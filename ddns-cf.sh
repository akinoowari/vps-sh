#!/usr/bin/env bash
#
# Cloudflare DDNS 一键管理脚本
#
# 功能:
# 1. 交互式安装和配置
# 2. 查看当前配置
# 3. 更新现有配置
# 4. 自动配置 Crontab 定时任务
# 5. 卸载脚本和所有相关文件
#
# Author: Hidden Lii
# Github: https://github.com/akinoowari/vps-sh
#

set -o errexit
set -o nounset
set -o pipefail

# --- 全局变量和常量 ---
DDNS_SCRIPT_PATH="/usr/local/bin/cf-ddns.sh"
CONFIG_PATH="/etc/cf-ddns.conf"
# 使用一个独特的注释来识别我们的 cron 任务
CRON_COMMENT="# Cloudflare DDNS Job"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 核心功能函数 ---

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：此脚本需要以 root 权限运行。${NC}"
        echo -e "${YELLOW}请尝试使用 'sudo' 执行, 例如: curl ... | sudo bash${NC}"
        exit 1
    fi
}

# 获取并显示当前状态
display_status() {
    clear
    echo -e "${BLUE}=====================================================${NC}"
    echo -e "${BLUE}        Cloudflare DDNS 一键管理脚本                ${NC}"
    echo -e "${BLUE}=====================================================${NC}"
    echo

    # 1. 检查安装状态
    if [ -f "$DDNS_SCRIPT_PATH" ]; then
        INSTALL_STATUS="${GREEN}已安装${NC}"
    else
        INSTALL_STATUS="${RED}未安装${NC}"
    fi

    # 2. 检查定时任务状态
    if crontab -l 2>/dev/null | grep -q "$CRON_COMMENT"; then
        CRON_STATUS="${GREEN}已开启${NC}"
    else
        CRON_STATUS="${RED}未开启${NC}"
    fi

    # 3. 获取公网 IP
    PUBLIC_IP=$(curl -s http://ipv4.icanhazip.com || echo "获取失败")

    echo -e "当前状态："
    echo -e "  - 脚本状态: ${INSTALL_STATUS}"
    echo -e "  - 定时任务: ${CRON_STATUS}"
    echo -e "  - 公网 IP : ${YELLOW}${PUBLIC_IP}${NC}"
    echo
}

# 1. 安装或覆盖脚本
install_or_update() {
    if [ -f "$DDNS_SCRIPT_PATH" ]; then
        echo -e "${YELLOW}警告：脚本已存在。继续操作将覆盖现有配置。${NC}"
        read -p "是否继续？[y/N]: " confirm
        if [[ "${confirm,,}" != "y" ]]; then
            echo "操作已取消。"
            return
        fi
    fi

    echo -e "${BLUE}--- 开始配置 Cloudflare DDNS ---${NC}"

    # 交互式收集信息
    read -p "请输入 Cloudflare Global API Key: " CFKEY
    read -p "请输入 Cloudflare 登录邮箱: " CFUSER
    read -p "请输入要操作的主域名 (例如: example.com): " CFZONE_NAME
    read -p "请输入要更新的记录名 (例如: home): " CFRECORD_NAME
    read -p "请输入记录类型 [A/AAAA] (默认 A): " CFRECORD_TYPE
    CFRECORD_TYPE=${CFRECORD_TYPE:-A}
    CFRECORD_TYPE=$(echo "$CFRECORD_TYPE" | tr 'a-z' 'A-Z')

    echo -e "${YELLOW}(可选) 配置 Telegram 通知，如不使用请直接回车。${NC}"
    read -p "请输入 Telegram Bot Token: " TG_BOT_TOKEN
    read -p "请输入 Telegram Chat ID: " TG_CHAT_ID

    # 创建配置文件
    echo -e "${GREEN}正在创建配置文件...${NC}"
    mkdir -p "$(dirname "$CONFIG_PATH")"
    cat > "$CONFIG_PATH" <<EOL
# Cloudflare DDNS 配置文件
CFKEY="${CFKEY}"
CFUSER="${CFUSER}"
CFZONE_NAME="${CFZONE_NAME}"
CFRECORD_NAME="${CFRECORD_NAME}"
CFRECORD_TYPE="${CFRECORD_TYPE}"
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
EOL
    chmod 600 "$CONFIG_PATH"

    # 创建 DDNS 主脚本 (和您提供的原始脚本逻辑一致)
    echo -e "${GREEN}正在创建主脚本...${NC}"
    # 使用 'cat' 和 'EOL' 来避免变量替换问题
    cat > "$DDNS_SCRIPT_PATH" <<'EOL'
#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

CONFIG_FILE="/etc/cf-ddns.conf"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" || { echo "错误: 配置文件 $CONFIG_FILE 未找到!"; exit 1; }

CFTTL=120
FORCE=false

if [ "$CFRECORD_TYPE" = "A" ]; then
  WANIPSITE="http://ipv4.icanhazip.com"
elif [ "$CFRECORD_TYPE" = "AAAA" ]; then
  WANIPSITE="http://ipv6.icanhazip.com"
else
  echo "配置文件中的 CFRECORD_TYPE ('$CFRECORD_TYPE') 无效。"
  exit 2
fi

send_telegram_message() {
    local message="$1"
    if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
        local hostname=$(hostname)
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        local full_message="🔄 *DDNS Update - $hostname*%0A%0A⏰ Time: \`$timestamp\`%0A🌐 Domain: \`$CFRECORD_NAME\`%0A$message"
        curl -s -o /dev/null -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" -d "chat_id=$TG_CHAT_ID" -d "text=$full_message" -d "parse_mode=Markdown" || echo "警告: 发送 Telegram 通知失败。"
    fi
}

if [ -z "${CFKEY:-}" ] || [ -z "${CFUSER:-}" ] || [ -z "${CFRECORD_NAME:-}" ]; then
  echo "错误: 配置文件中的一个或多个必要字段为空。"
  exit 2
fi

if [ "$CFRECORD_NAME" != "$CFZONE_NAME" ] && ! [[ "$CFRECORD_NAME" == *"$CFZONE_NAME" ]]; then
  CFRECORD_NAME="$CFRECORD_NAME.$CFZONE_NAME"
fi

WAN_IP=$(curl -s "$WANIPSITE")
[ -z "$WAN_IP" ] && { echo "错误: 无法获取公网IP。"; exit 1; }

WAN_IP_FILE="$HOME/.cf-wan_ip_${CFRECORD_NAME//./_}.txt"
OLD_WAN_IP=""
[ -f "$WAN_IP_FILE" ] && OLD_WAN_IP=$(cat "$WAN_IP_FILE")

if [ "$WAN_IP" = "$OLD_WAN_IP" ] && [ "$FORCE" = false ]; then
  # echo "IP 未变化 ($WAN_IP), 无需更新。" # 在 cron 中运行时静默
  exit 0
fi

ID_FILE="$HOME/.cf-id_${CFRECORD_NAME//./_}.txt"
if [ -f "$ID_FILE" ] && [ "$(sed -n '3p' "$ID_FILE")" == "$CFZONE_NAME" ] && [ "$(sed -n '4p' "$ID_FILE")" == "$CFRECORD_NAME" ]; then
    CFZONE_ID=$(sed -n '1p' "$ID_FILE")
    CFRECORD_ID=$(sed -n '2p' "$ID_FILE")
else
    CFZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1)
    [ -z "$CFZONE_ID" ] && { echo "错误: 无法获取 Zone ID。"; send_telegram_message "❌ *DNS Update Failed*%0A%0A⚠️ Error: 无法获取 Zone ID"; exit 1; }
    CFRECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records?name=$CFRECORD_NAME&type=$CFRECORD_TYPE" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1)
    [ -z "$CFRECORD_ID" ] && { echo "错误: 无法获取 Record ID for '$CFRECORD_NAME'。"; send_telegram_message "❌ *DNS Update Failed*%0A%0A⚠️ Error: 无法获取 Record ID"; exit 1; }
    echo -e "$CFZONE_ID\n$CFRECORD_ID\n$CFZONE_NAME\n$CFRECORD_NAME" > "$ID_FILE"
fi

RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json" --data "{\"type\":\"$CFRECORD_TYPE\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$WAN_IP\", \"ttl\":$CFTTL, \"proxied\":false}")

if [[ "$RESPONSE" == *"\"success\":true"* ]]; then
  echo "✔ 更新成功！新 IP: $WAN_IP"
  echo "$WAN_IP" > "$WAN_IP_FILE"
  send_telegram_message "✅ *DNS Update Successful*%0A%0A📍 Old IP: \`$OLD_WAN_IP\`%0A📍 New IP: \`$WAN_IP\`"
  exit 0
else
  echo "❌ 更新失败！API 返回: $RESPONSE"
  send_telegram_message "❌ *DNS Update Failed*%0A%0A📍 Attempted IP: \`$WAN_IP\`%0A⚠️ Error: API 请求失败"
  exit 1
fi
EOL
    chmod +x "$DDNS_SCRIPT_PATH"

    echo -e "${GREEN}✔ 安装/更新完成！${NC}"
    echo "你可以手动运行一次进行测试: ${YELLOW}${DDNS_SCRIPT_PATH}${NC}"
}

# 2. 查看配置
view_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}错误：未找到配置文件，请先执行安装。${NC}"
        return
    fi
    echo -e "${BLUE}--- 当前配置 ---${NC}"
    # 隐藏 API Key，只显示后4位
    local conf_content
    conf_content=$(cat "$CONFIG_PATH")
    local masked_key
    masked_key=$(echo "$conf_content" | grep "CFKEY" | sed -E 's/(CFKEY=".*)(....")/\1****"/')
    echo "$conf_content" | grep -v "CFKEY"
    echo "$masked_key"
    echo -e "${BLUE}------------------${NC}"
}

# 3. 更新配置
update_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}错误：未找到配置文件，请先执行安装。${NC}"
        return
    fi

    source "$CONFIG_PATH" # 加载当前配置

    echo -e "${BLUE}--- 更新配置 (不输入则保留原值) ---${NC}"

    read -p "新 API Key [当前: ****${CFKEY: -4}]: " new_val && CFKEY=${new_val:-$CFKEY}
    read -p "新登录邮箱 [当前: $CFUSER]: " new_val && CFUSER=${new_val:-$CFUSER}
    read -p "新主域名 [当前: $CFZONE_NAME]: " new_val && CFZONE_NAME=${new_val:-$CFZONE_NAME}
    read -p "新记录名 [当前: $CFRECORD_NAME]: " new_val && CFRECORD_NAME=${new_val:-$CFRECORD_NAME}
    read -p "新记录类型 (A/AAAA) [当前: $CFRECORD_TYPE]: " new_val && CFRECORD_TYPE=${new_val:-$CFRECORD_TYPE}
    read -p "新 Telegram Bot Token [当前: ${TG_BOT_TOKEN:-空}]: " new_val && TG_BOT_TOKEN=${new_val:-$TG_BOT_TOKEN}
    read -p "新 Telegram Chat ID [当前: ${TG_CHAT_ID:-空}]: " new_val && TG_CHAT_ID=${new_val:-$TG_CHAT_ID}

    # 重新写入配置文件
    cat > "$CONFIG_PATH" <<EOL
CFKEY="${CFKEY}"
CFUSER="${CFUSER}"
CFZONE_NAME="${CFZONE_NAME}"
CFRECORD_NAME="${CFRECORD_NAME}"
CFRECORD_TYPE="${CFRECORD_TYPE}"
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
EOL
    # 删除旧的ID缓存文件，强制下次运行时重新获取
    rm -f "$HOME/.cf-id_"*
    echo -e "${GREEN}✔ 配置已更新！下次脚本运行时将使用新配置。${NC}"
}

# 4. 配置定时任务
configure_cron() {
    if [ ! -f "$DDNS_SCRIPT_PATH" ]; then
        echo -e "${RED}错误：脚本未安装，无法配置定时任务。${NC}"
        return
    fi

    if crontab -l 2>/dev/null | grep -q "$CRON_COMMENT"; then
        echo -e "${YELLOW}定时任务已存在，无需重复配置。${NC}"
        return
    fi

    # 每5分钟执行一次
    CRON_JOB="*/5 * * * * $DDNS_SCRIPT_PATH >/dev/null 2>&1 $CRON_COMMENT"

    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

    if crontab -l | grep -q "$CRON_COMMENT"; then
        echo -e "${GREEN}✔ 定时任务已成功配置！将每5分钟执行一次。${NC}"
    else
        echo -e "${RED}❌ 配置定时任务失败。请检查 crontab 服务是否正常。${NC}"
    fi
}

# 5. 卸载
uninstall() {
    echo -e "${YELLOW}警告：此操作将删除脚本、配置文件和定时任务。${NC}"
    read -p "确定要卸载吗？[y/N]: " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        echo "操作已取消。"
        return
    fi

    # 删除定时任务
    if crontab -l 2>/dev/null | grep -q "$CRON_COMMENT"; then
        crontab -l | grep -v "$CRON_COMMENT" | crontab -
        echo "定时任务已移除。"
    fi

    # 删除脚本和配置文件
    rm -f "$DDNS_SCRIPT_PATH"
    echo "主脚本 '$DDNS_SCRIPT_PATH' 已删除。"
    rm -f "$CONFIG_PATH"
    echo "配置文件 '$CONFIG_PATH' 已删除。"

    # 删除缓存文件
    rm -f "$HOME/.cf-wan_ip_"* "$HOME/.cf-id_"*
    echo "IP及ID缓存文件已删除。"

    echo -e "${GREEN}✔ 卸载完成。${NC}"
}


# --- 主菜单循环 ---
main_menu() {
    while true; do
        display_status
        echo -e "-----------------------------------------------------"
        echo -e "${BLUE}欢迎使用 Cloudflare DDNS 一键管理脚本！${NC}"
        echo -e "请在使用此脚本前现在 Cloudflare 中创建想要添加的域名的 DNS 记录"
        echo -e "-----------------------------------------------------"
        echo -e "请选择要执行的操作:"
        echo -e "  ${YELLOW}1.${NC} 安装 / 覆盖 DDNS 脚本"
        echo -e "  ${YELLOW}2.${NC} 查看当前配置"
        echo -e "  ${YELLOW}3.${NC} 更新当前配置"
        echo -e "  ${YELLOW}4.${NC} 配置定时任务"
        echo -e "  ${YELLOW}5.${NC} ${RED}卸载${NC}"
        echo "-----------------------------------------------------"
        echo -e "  ${YELLOW}q.${NC} 退出脚本"
        echo

        read -p "请输入选项 [1-5, q]: " choice

        case "$choice" in
            1) install_or_update ;;
            2) view_config ;;
            3) update_config ;;
            4) configure_cron ;;
            5) uninstall ;;
            q|Q)
                echo "感谢使用，再见！"
                exit 0
                ;;
            *)
                echo -e "${RED}输入无效，请重新输入。${NC}"
                ;;
        esac
        echo
        read -p "按任意键返回主菜单..." -n 1 -s
    done
}

# --- 脚本入口 ---
check_root
main_menu