#!/usr/bin/env bash
#
# Cloudflare DDNS 一键管理脚本
#
# 功能:
# 1. 交互式安装和配置
# 2. 查看当前配置
# 3. 更新现有配置
# 4. 自动配置 Crontab 定时任务
# 5. 修改定时任务执行周期
# 6. 立即执行 DNS 更新
# 7. 测试 Telegram 通知功能
# 8. 卸载脚本和所有相关文件
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
CRON_COMMENT="# Cloudflare DDNS Job"
CACHE_DIR="/var/tmp"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 核心功能函数 ---
# (大部分函数未变，为节省篇幅省略)

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：此脚本需要以 root 权限运行。${NC}"
        echo -e "${YELLOW}请尝试使用 'sudo' 执行。${NC}"
        exit 1
    fi
}

# 获取并显示当前状态
display_status() {
    clear
    echo -e "${BLUE}=====================================================${NC}"
    echo -e "${BLUE}      Cloudflare DDNS 一键管理脚本 (v10)            ${NC}"
    echo -e "${BLUE}=====================================================${NC}"
    echo

    # 1. 检查安装状态
    INSTALL_STATUS="${RED}未安装${NC}"
    [ -f "$DDNS_SCRIPT_PATH" ] && INSTALL_STATUS="${GREEN}已安装${NC}"

    # 2. 检查定时任务状态
    CRON_STATUS="${RED}未开启${NC}"
    if command -v crontab &>/dev/null; then
        crontab -l 2>/dev/null | grep -q "$CRON_COMMENT" && CRON_STATUS="${GREEN}已开启${NC}"
    fi

    # 3. 获取公网 IP
    PUBLIC_IP=$(curl -s http://ipv4.icanhazip.com || echo "获取失败")

    echo -e "当前状态："
    echo -e "  - 脚本状态: ${INSTALL_STATUS}"
    echo -e "  - 定时任务: ${CRON_STATUS}"
    echo -e "  - 公网 IP : ${YELLOW}${PUBLIC_IP}${NC}"
    echo
}

# 安装定时任务服务
install_cron_service() {
    echo -e "${YELLOW}检测到 'cron' 服务未安装，正在尝试自动安装...${NC}"

    if [ -f /etc/os-release ]; then
        source /etc/os-release
        OS_ID=$ID
    else
        echo -e "${RED}无法识别的操作系统，请手动安装 cron 服务。${NC}"
        return 1
    fi

    case $OS_ID in
        ubuntu|debian|raspbian)
            echo -e "${GREEN}检测到 Debian/Ubuntu 系统，使用 apt...${NC}"
            apt-get update -qq >/dev/null
            apt-get install -y cron
            systemctl enable --now cron
            ;;
        centos|rhel|fedora|rocky|almalinux)
            echo -e "${GREEN}检测到 RHEL/CentOS/Fedora 系统，使用 yum/dnf...${NC}"
            if command -v dnf &>/dev/null; then
                dnf install -y cronie
            else
                yum install -y cronie
            fi
            systemctl enable --now crond
            ;;
        alpine)
            echo -e "${GREEN}检测到 Alpine 系统，使用 apk...${NC}"
            apk add dcron
            rc-update add dcron default
            rc-service dcron start
            ;;
        *)
            echo -e "${RED}不支持的操作系统: $OS_ID。请手动安装 cron 服务。${NC}"
            return 1
            ;;
    esac

    if command -v crontab &>/dev/null; then
        echo -e "${GREEN}✔ cron 服务已成功安装并启动！${NC}"
    else
        echo -e "${RED}❌ cron 服务安装失败，请检查上面的错误信息。${NC}"
    fi
}

# 1. 安装或覆盖脚本
install_or_update() {
    if [ -f "$DDNS_SCRIPT_PATH" ]; then
        echo -e "${YELLOW}警告：脚本已存在。继续操作将覆盖现有配置。${NC}"
        read -p "是否继续？[y/N]: " confirm
        local lower_confirm=${confirm,,}
        if [[ "$lower_confirm" != "y" && "$lower_confirm" != "yes" ]]; then
            echo "操作已取消。"
            return
        fi
    fi

    echo -e "${BLUE}--- 开始配置 Cloudflare DDNS ---${NC}"

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

    echo -e "${GREEN}正在创建主脚本...${NC}"
    cat > "$DDNS_SCRIPT_PATH" <<'EOL'
#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

CONFIG_FILE="/etc/cf-ddns.conf"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" || { echo "错误: 配置文件 $CONFIG_FILE 未找到!"; exit 1; }

CFTTL=120
FORCE=${FORCE:-false}
CACHE_DIR="/var/tmp"

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

SAFE_RECORD_NAME=$(echo "$CFRECORD_NAME" | tr './' '__')
WAN_IP_FILE="${CACHE_DIR}/cf-wan_ip_${SAFE_RECORD_NAME}.txt"
ID_FILE="${CACHE_DIR}/cf-id_${SAFE_RECORD_NAME}.txt"

OLD_WAN_IP=""
[ -f "$WAN_IP_FILE" ] && OLD_WAN_IP=$(cat "$WAN_IP_FILE")

if [ "$WAN_IP" = "$OLD_WAN_IP" ] && [ "$FORCE" = false ]; then
  exit 0
fi

if [ -f "$ID_FILE" ] && [ -s "$ID_FILE" ] && [ "$(sed -n '3p' "$ID_FILE")" == "$CFZONE_NAME" ] && [ "$(sed -n '4p' "$ID_FILE")" == "$CFRECORD_NAME" ]; then
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
  send_telegram_message "✅ *DNS Update Successful*%0A%0A📍 Old IP: \`${OLD_WAN_IP:-首次记录}\`%0A📍 New IP: \`$WAN_IP\`"
  exit 0
else
  echo "❌ 更新失败！API 返回: $RESPONSE"
  send_telegram_message "❌ *DNS Update Failed*%0A%0A📍 Attempted IP: \`$WAN_IP\`%0A⚠️ Error: API 请求失败"
  exit 1
fi
EOL
    chmod +x "$DDNS_SCRIPT_PATH"

    echo -e "${GREEN}✔ 安装/更新完成！${NC}"
    echo -e "你可以手动运行一次进行测试: ${YELLOW}${DDNS_SCRIPT_PATH}${NC}"
}

# 2. 查看配置
view_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}错误：未找到配置文件，请先执行安装。${NC}"
        return
    fi
    echo -e "${BLUE}--- 当前配置 ---${NC}"
    awk -F'=' '
        BEGIN {OFS="="}
        /CFKEY/ {
            gsub(/"/, "", $2);
            printf "%s=\"****%s\"\n", $1, substr($2, length($2)-3);
        }
        !/CFKEY/ {print}
    ' "$CONFIG_PATH"
    echo -e "${BLUE}------------------${NC}"
}

# 3. 更新配置
update_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}错误：未找到配置文件，请先执行安装。${NC}"
        return
    fi

    source "$CONFIG_PATH"

    echo -e "${BLUE}--- 更新配置 (不输入则保留原值) ---${NC}"

    read -p "新 API Key [当前: ****${CFKEY: -4}]: " new_val && CFKEY=${new_val:-$CFKEY}
    read -p "新登录邮箱 [当前: $CFUSER]: " new_val && CFUSER=${new_val:-$CFUSER}
    read -p "新主域名 [当前: $CFZONE_NAME]: " new_val && CFZONE_NAME=${new_val:-$CFZONE_NAME}
    read -p "新记录名 [当前: $CFRECORD_NAME]: " new_val && CFRECORD_NAME=${new_val:-$CFRECORD_NAME}
    read -p "新记录类型 (A/AAAA) [当前: $CFRECORD_TYPE]: " new_val && CFRECORD_TYPE=${new_val:-$CFRECORD_TYPE}
    read -p "新 Telegram Bot Token [当前: ${TG_BOT_TOKEN:-空}]: " new_val && TG_BOT_TOKEN=${new_val:-$TG_BOT_TOKEN}
    read -p "新 Telegram Chat ID [当前: ${TG_CHAT_ID:-空}]: " new_val && TG_CHAT_ID=${new_val:-$TG_CHAT_ID}

    cat > "$CONFIG_PATH" <<EOL
CFKEY="${CFKEY}"
CFUSER="${CFUSER}"
CFZONE_NAME="${CFZONE_NAME}"
CFRECORD_NAME="${CFRECORD_NAME}"
CFRECORD_TYPE="${CFRECORD_TYPE}"
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
EOL
    rm -f ${CACHE_DIR}/cf-*
    echo -e "${GREEN}✔ 配置已更新！所有缓存已清除，下次将重新获取。${NC}"
}

# 4. 配置定时任务
configure_cron() {
    if [ ! -f "$DDNS_SCRIPT_PATH" ]; then
        echo -e "${RED}错误：脚本未安装，无法配置定时任务。${NC}"
        return
    fi

    if ! command -v crontab &>/dev/null; then
        install_cron_service
        echo -e "${YELLOW}Cron 服务安装流程已完成。请返回主菜单后，再次选择选项 4 来添加定时任务。${NC}"
        return
    fi

    if crontab -l 2>/dev/null | grep -q "$CRON_COMMENT"; then
        echo -e "${YELLOW}定时任务已存在，无需重复配置。如需修改周期，请使用 “修改执行周期” 选项。${NC}"
        return
    fi

    local cron_minute
    read -p "请输入脚本的执行周期（分钟），范围在 1-60 之间 (默认: 5): " cron_minute
    cron_minute=${cron_minute:-5}

    while ! [[ "$cron_minute" =~ ^[0-9]+$ ]] || [ "$cron_minute" -lt 1 ] || [ "$cron_minute" -gt 60 ]; do
        echo -e "${RED}输入无效，请输入 1 到 60 之间的整数。${NC}"
        read -p "请重新输入执行周期（分钟）[1-60] (默认: 5): " cron_minute
        cron_minute=${cron_minute:-5}
    done

    echo "正在添加定时任务..."
    local CRON_JOB="*/${cron_minute} * * * * $DDNS_SCRIPT_PATH >/dev/null 2>&1 $CRON_COMMENT"

    # --- 使用临时文件，彻底避免 I/O 问题 ---
    local tmp_cron_file
    tmp_cron_file=$(mktemp)
    # 先将现有的 crontab 内容（如果有的话）写入临时文件
    crontab -l 2>/dev/null > "$tmp_cron_file"
    # 然后将我们的新任务追加到文件末尾
    echo "$CRON_JOB" >> "$tmp_cron_file"
    # 从临时文件加载新的 crontab
    crontab "$tmp_cron_file"
    # 清理临时文件
    rm "$tmp_cron_file"

    if crontab -l 2>/dev/null | grep -q "$CRON_COMMENT"; then
        echo -e "${GREEN}✔ 定时任务已成功配置！将每 ${cron_minute} 分钟执行一次。${NC}"
    else
        echo -e "${RED}❌ 配置定时任务失败。请检查 crontab 服务是否正常。${NC}"
    fi
}

# 5. 修改定时任务周期
modify_cron_period() {
    if [ ! -f "$DDNS_SCRIPT_PATH" ]; then
        echo -e "${RED}错误：脚本未安装，无法修改定时任务。${NC}"
        return
    fi

    if ! crontab -l 2>/dev/null | grep -q "$CRON_COMMENT"; then
        echo -e "${RED}错误：未找到定时任务。请先使用选项 '4' 进行配置。${NC}"
        return
    fi

    local cron_minute
    read -p "请输入新的执行周期（分钟），范围在 1-60 之间 (默认: 5): " cron_minute
    cron_minute=${cron_minute:-5}

    while ! [[ "$cron_minute" =~ ^[0-9]+$ ]] || [ "$cron_minute" -lt 1 ] || [ "$cron_minute" -gt 60 ]; do
        echo -e "${RED}输入无效，请输入 1 到 60 之间的整数。${NC}"
        read -p "请重新输入执行周期（分钟）[1-60] (默认: 5): " cron_minute
        cron_minute=${cron_minute:-5}
    done

    echo "正在修改定时任务周期..."
    local new_cron_job_line="*/${cron_minute} * * * * $DDNS_SCRIPT_PATH >/dev/null 2>&1 $CRON_COMMENT"

    # --- 使用临时文件和 grep -v 的健壮模式 ---
    local tmp_cron_file
    tmp_cron_file=$(mktemp)

    # 1. 先将不含我们任务的其他所有行写入临时文件
    crontab -l 2>/dev/null | grep -v "$CRON_COMMENT" > "$tmp_cron_file" || true

    # 2. 然后将我们的新任务行追加到文件末尾
    echo "$new_cron_job_line" >> "$tmp_cron_file"

    # 3. 从临时文件加载新的 crontab
    crontab "$tmp_cron_file"

    # 4. 清理临时文件
    rm "$tmp_cron_file"

    echo -e "${GREEN}✔ 定时任务周期已成功修改为每 ${cron_minute} 分钟执行一次！${NC}"
}

# 6. 强制执行 DNS 更新
force_dns_update() {
    if [ ! -f "$DDNS_SCRIPT_PATH" ]; then
        echo -e "${RED}错误：脚本未安装，无法执行更新。${NC}"
        return
    fi
    echo -e "${YELLOW}正在强制执行 DNS 更新...${NC}"
    if FORCE=true "$DDNS_SCRIPT_PATH"; then
        echo -e "${GREEN}✔ 强制更新执行成功。${NC}"
    else
        echo -e "${RED}❌ 强制更新执行失败，请查看上面的日志。${NC}"
    fi
}

# 7. 测试 Telegram 通知
test_telegram() {
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${RED}错误：未找到配置文件，请先执行安装。${NC}"
        return
    fi

    source "$CONFIG_PATH"

    if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
        echo -e "${RED}错误：Telegram Bot Token 或 Chat ID 未配置。${NC}"
        echo -e "${YELLOW}请使用选项 '3' 更新配置。${NC}"
        return
    fi

    echo -e "${YELLOW}正在发送测试消息...${NC}"

    local hostname=$(hostname)
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local test_message="👋 *Hello from DDNS script!*%0A%0AThis is a test message from \`$hostname\` at \`$timestamp\`."

    response=$(curl -s -w "%{http_code}" -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d "chat_id=$TG_CHAT_ID" \
        -d "text=$test_message" \
        -d "parse_mode=Markdown")

    http_code="${response: -3}"

    if [ "$http_code" = "200" ]; then
        echo -e "${GREEN}✔ 测试消息发送成功！请检查你的 Telegram。${NC}"
    else
        echo -e "${RED}❌ 测试消息发送失败！${NC}"
        echo -e "API 返回 HTTP 状态码: ${YELLOW}${http_code}${NC}"
        echo "响应内容: ${response%???}"
    fi
}

# 8. 卸载
uninstall() {
    echo -e "${YELLOW}警告：此操作将删除脚本、配置文件、定时任务和所有缓存文件。${NC}"
    read -p "确定要卸载吗？[y/N]: " confirm

    local lower_confirm=${confirm,,}
    if [[ "$lower_confirm" == "y" || "$lower_confirm" == "yes" ]]; then
        echo "正在执行卸载操作..."

        # 检查 crontab 命令是否存在
        if command -v crontab &>/dev/null; then
            # 只有在 crontab 包含我们的任务时才执行修改
            if crontab -l 2>/dev/null | grep -q "$CRON_COMMENT"; then
                echo "检测到定时任务，正在移除..."
                # 使用临时文件，这是最安全的方式
                local tmp_cron_file
                tmp_cron_file=$(mktemp)

                # --- 这是终极修复后的关键行 ---
                # 在 grep 命令后加上 || true，以防止在没有其他 cron job 时脚本因 pipefail 而退出
                crontab -l 2>/dev/null | grep -v "$CRON_COMMENT" > "$tmp_cron_file" || true

                # 从临时文件加载新的 crontab
                crontab "$tmp_cron_file"
                echo "定时任务配置已更新。"

                # 清理临时文件
                rm "$tmp_cron_file"
            fi
        fi

        # 即使 crontab 操作不存在或失败，也继续删除文件
        rm -f "$DDNS_SCRIPT_PATH"
        echo "主脚本 '$DDNS_SCRIPT_PATH' 已删除。"
        rm -f "$CONFIG_PATH"
        echo "配置文件 '$CONFIG_PATH' 已删除。"

        rm -f ${CACHE_DIR}/cf-*
        echo "位于 ${CACHE_DIR} 的缓存文件已删除。"

        echo -e "${GREEN}✔ 卸载完成。${NC}"
    else
        echo "操作已取消。"
    fi
}


main_menu() {
    while true; do
        display_status
        echo -e "请选择要执行的操作:"
        echo -e "  ${YELLOW}1.${NC} 安装 / 覆盖 DDNS 脚本"
        echo -e "  ${YELLOW}2.${NC} 查看当前配置"
        echo -e "  ${YELLOW}3.${NC} 更新当前配置"
        echo -e "  ${YELLOW}4.${NC} 配置定时任务"
        echo -e "  ${YELLOW}5.${NC} ${GREEN}修改执行周期${NC}"
        echo -e "  ${YELLOW}6.${NC} ${GREEN}立即更新DNS记录${NC}"
        echo -e "  ${YELLOW}7.${NC} ${GREEN}测试 Telegram 通知${NC}"
        echo -e "  ${YELLOW}8.${NC} ${RED}卸载脚本${NC}"
        echo "-----------------------------------------------------"
        echo -e "  ${YELLOW}q.${NC} 退出脚本"
        echo

        read -p "请输入选项 [1-8, q]: " choice

        case "$choice" in
            1) install_or_update ;;
            2) view_config ;;
            3) update_config ;;
            4) configure_cron ;;
            5) modify_cron_period ;;
            6) force_dns_update ;;
            7) test_telegram ;;
            8) uninstall ;;
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