#!/bin/bash
# realm.sh - Realm 管理脚本 v1.2

# 全局配置
REALM_DIR="/etc/realm"
CONFIG_FILE="$REALM_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
REALM_BIN="$REALM_DIR/realm"
REPO_URL="https://api.github.com/repos/zhboner/realm/releases/latest"
INSTALLED_VERSION=""
LATEST_VERSION=""
SCRIPT_NAME=$(basename "$0")
SCRIPT_PATH=$(realpath "$0")

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 初始化检查
initialize() {
    # 1. 检查root权限
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误：此脚本必须以root权限运行！${NC}"
        exit 1
    fi
    
    # 2. 检查系统是否为Debian 11
    if ! grep -q 'Debian GNU/Linux 11' /etc/os-release; then
        echo -e "${YELLOW}警告：此脚本专为Debian 11设计，其他系统可能不兼容${NC}"
        read -p "是否继续？(y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # 3. 创建必要目录
    mkdir -p "$REALM_DIR"
    
    # 4. 检查并安装必要依赖
    local missing_deps=()
    for dep in wget tar curl jq; do
        if ! command -v $dep &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${YELLOW}正在安装必要依赖: ${missing_deps[*]}...${NC}"
        apt update > /dev/null 2>&1
        apt install -y "${missing_deps[@]}" > /dev/null 2>&1
    fi
    
    # 5. 检查curl是否正常工作
    if ! curl -s --connect-timeout 5 https://github.com > /dev/null; then
        echo -e "${RED}网络连接检查失败，请确保网络正常！${NC}"
        exit 1
    fi
    
    # 6. 加载已安装版本信息
    if [ -f "$REALM_BIN" ]; then
        INSTALLED_VERSION=$("$REALM_BIN" -v 2>/dev/null | awk '{print $2}')
    fi
}

# 获取最新版本
get_latest_version() {
    LATEST_VERSION=$(curl -s "$REPO_URL" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${YELLOW}警告：无法获取最新版本号，使用默认版本 v2.7.0${NC}"
        LATEST_VERSION="v2.7.0"
    fi
}

# 安装/更新Realm
install_realm() {
    initialize
    get_latest_version
    
    if [ -n "$INSTALLED_VERSION" ]; then
        echo -e "${YELLOW}检测到已安装版本: ${CYAN}$INSTALLED_VERSION${NC}"
        if [ "$INSTALLED_VERSION" == "$LATEST_VERSION" ]; then
            echo -e "${GREEN}已是最新版本，无需更新${NC}"
            return
        else
            echo -e "${YELLOW}发现新版本: ${CYAN}$LATEST_VERSION${NC}"
            echo -e "${YELLOW}正在更新Realm...${NC}"
        fi
    else
        echo -e "${YELLOW}正在安装Realm...${NC}"
    fi
    
    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/$LATEST_VERSION/realm-x86_64-unknown-linux-gnu.tar.gz"
    
    wget -P "$REALM_DIR" "$DOWNLOAD_URL" > /dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败，请检查网络连接！${NC}"
        exit 1
    fi
    
    tar -zxvf "$REALM_DIR/realm-x86_64-unknown-linux-gnu.tar.gz" -C "$REALM_DIR" > /dev/null
    chmod +x "$REALM_BIN"
    rm -f "$REALM_DIR"/*.tar.gz
    
    # 创建配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << EOF
[network]
use_udp = true
no_tcp = false
EOF
    fi
    
    # 创建服务文件
    if [ ! -f "$SERVICE_FILE" ]; then
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Realm Service
After=network.target

[Service]
ExecStart=$REALM_BIN -c $CONFIG_FILE
WorkingDirectory=$REALM_DIR
Restart=always
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
    
    # 重新加载安装信息
    if [ -f "$REALM_BIN" ]; then
        INSTALLED_VERSION=$("$REALM_BIN" -v 2>/dev/null | awk '{print $2}')
    fi
    
    echo -e "${GREEN}Realm ${CYAN}${INSTALLED_VERSION:-新版本}${GREEN} 安装/更新成功！${NC}"
}

# 添加转发规则
add_rule() {
    initialize
    
    if [ -z "$INSTALLED_VERSION" ]; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    echo -e "\n${BLUE}添加新的转发规则${NC}"
    read -p "请输入监听地址 (例如: 0.0.0.0:23456): " listen_addr
    read -p "请输入目标地址 (例如: target.com:23456): " remote_addr
    
    # 验证输入格式
    if ! [[ $listen_addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
        echo -e "${RED}监听地址格式错误！${NC}"
        return
    fi
    
    if ! [[ $remote_addr =~ ^.+:[0-9]+$ ]]; then
        echo -e "${RED}目标地址格式错误！${NC}"
        return
    fi
    
    # 添加到配置文件
    cat >> "$CONFIG_FILE" << EOF

[[endpoints]]
listen = "$listen_addr"
remote = "$remote_addr"
EOF
    
    echo -e "${GREEN}规则添加成功！${NC}"
    restart_service
}

# 查看转发规则
view_rules() {
    initialize
    
    if [ -z "$INSTALLED_VERSION" ]; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    echo -e "\n${BLUE}当前转发规则：${NC}"
    if [ ! -s "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}没有配置任何转发规则${NC}"
        return
    fi
    
    awk '/\[\[endpoints\]\]/{f=1; count++; print "规则 "count":"} 
         f && /listen|remote/{print "  "$0} 
         /^$/{f=0}' "$CONFIG_FILE"
}

# 删除转发规则
delete_rule() {
    initialize
    
    if [ -z "$INSTALLED_VERSION" ]; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    view_rules
    if [ -z "$(grep '\[endpoints\]' "$CONFIG_FILE")" ]; then
        return
    fi
    
    read -p "请输入要删除的规则编号: " rule_num
    
    # 验证输入
    if ! [[ "$rule_num" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}无效的规则编号！${NC}"
        return
    fi
    
    local rule_count=$(grep -c '\[\[endpoints\]\]' "$CONFIG_FILE")
    if [ "$rule_num" -lt 1 ] || [ "$rule_num" -gt "$rule_count" ]; then
        echo -e "${RED}无效的规则编号！${NC}"
        return
    fi
    
    # 生成临时配置
    awk -v rule_num=$rule_num '
        BEGIN { count = 0 }
        /\[\[endpoints\]\]/ {
            count++
            if (count == rule_num) {
                skip = 1
                next
            }
        }
        skip && /^$/ { skip = 0; next }
        skip { next }
        { print }
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
    
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    echo -e "${GREEN}规则 #$rule_num 已删除！${NC}"
    restart_service
}

# 服务管理
start_service() {
    initialize
    
    if [ -z "$INSTALLED_VERSION" ]; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    systemctl start realm
    echo -e "${GREEN}服务已启动！${NC}"
}

stop_service() {
    initialize
    
    if [ -z "$INSTALLED_VERSION" ]; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    systemctl stop realm
    echo -e "${YELLOW}服务已停止！${NC}"
}

restart_service() {
    initialize
    
    if [ -z "$INSTALLED_VERSION" ]; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    systemctl restart realm
    echo -e "${BLUE}服务已重启！${NC}"
}

# 查看日志
view_logs() {
    initialize
    
    if [ -z "$INSTALLED_VERSION" ]; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    journalctl -u realm -f
}

# 定时任务管理
cron_management() {
    initialize
    echo -e "\n${BLUE}定时任务管理${NC}"
    echo "1. 添加自动更新任务（每天自动检查更新）"
    echo "2. 移除自动更新任务"
    echo "3. 查看当前定时任务"
    echo "4. 返回主菜单"
    
    read -p "请选择: " cron_choice
    
    case $cron_choice in
        1)
            # 添加每天自动更新
            (crontab -l 2>/dev/null; echo "0 3 * * * $SCRIPT_PATH --update >/dev/null 2>&1") | crontab -
            echo -e "${GREEN}自动更新任务已添加！${NC}"
            ;;
        2)
            # 移除任务
            crontab -l | grep -v "$SCRIPT_PATH" | crontab -
            echo -e "${YELLOW}自动更新任务已移除！${NC}"
            ;;
        3)
            echo -e "\n${CYAN}当前定时任务：${NC}"
            crontab -l | grep "$SCRIPT_PATH"
            ;;
        4) return ;;
        *) echo -e "${RED}无效选项！${NC}" ;;
    esac
}

# 卸载Realm
uninstall_realm() {
    initialize
    
    if [ -z "$INSTALLED_VERSION" ]; then
        echo -e "${YELLOW}Realm 未安装，无需卸载${NC}"
        return
    fi
    
    echo -e "\n${RED}正在卸载Realm...${NC}"
    systemctl stop realm
    systemctl disable realm
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$REALM_DIR"
    crontab -l | grep -v "$SCRIPT_PATH" | crontab -
    echo -e "${GREEN}Realm 已完全卸载！${NC}"
    
    # 重置版本信息
    INSTALLED_VERSION=""
}

# 显示系统信息
show_system_info() {
    echo -e "${CYAN}系统信息: ${NC}$(lsb_release -ds) ($(lsb_release -cs))"
    echo -e "${CYAN}内核版本: ${NC}$(uname -r)"
    echo -e "${CYAN}架构: ${NC}$(uname -m)"
    echo -e "${CYAN}脚本路径: ${NC}$SCRIPT_PATH"
}

# 显示状态信息
show_status() {
    if [ -n "$INSTALLED_VERSION" ]; then
        echo -e "${GREEN}Realm 状态: ${CYAN}已安装 ($INSTALLED_VERSION)${NC}"
        systemctl is-active --quiet realm && \
            echo -e "${GREEN}服务状态: ${CYAN}运行中${NC}" || \
            echo -e "${YELLOW}服务状态: ${RED}未运行${NC}"
    else
        echo -e "${YELLOW}Realm 状态: ${RED}未安装${NC}"
    fi
    
    # 检查定时任务
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH"; then
        echo -e "${GREEN}自动更新: ${CYAN}已启用${NC}"
    else
        echo -e "${YELLOW}自动更新: ${RED}未启用${NC}"
    fi
}

# 显示菜单
show_menu() {
    clear
    echo -e "\n${GREEN}Realm 管理脚本 v1.2${NC}"
    echo "========================================"
    show_system_info
    echo "----------------------------------------"
    show_status
    echo "========================================"
    echo "1. 安装/更新 Realm"
    echo "2. 添加转发规则"
    echo "3. 查看转发规则"
    echo "4. 删除转发规则"
    echo "5. 启动服务"
    echo "6. 停止服务"
    echo "7. 重启服务"
    echo "8. 查看日志"
    echo "9. 定时任务管理"
    echo "10. 卸载 Realm"
    echo "0. 退出脚本"
    echo "========================================"
}

# 主函数
main() {
    while true; do
        show_menu
        read -p "请选择操作: " choice
        
        case $choice in
            1) install_realm ;;
            2) add_rule ;;
            3) view_rules ;;
            4) delete_rule ;;
            5) start_service ;;
            6) stop_service ;;
            7) restart_service ;;
            8) view_logs ;;
            9) cron_management ;;
            10) uninstall_realm ;;
            0) 
                echo -e "${GREEN}再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入！${NC}"
                ;;
        esac
        
        echo -e "\n按回车键继续..."
        read
    done
}

# 脚本入口
case "$1" in
    "--update")
        install_realm
        ;;
    *)
        # 初始加载版本信息
        if [ -f "$REALM_BIN" ]; then
            INSTALLED_VERSION=$("$REALM_BIN" -v 2>/dev/null | awk '{print $2}')
        fi
        main
        ;;
esac
