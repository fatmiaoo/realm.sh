#!/bin/bash

# Realm 高级管理脚本 (模块化设计)
# 支持服务端/客户端模式 | 规则管理 | 服务控制 | 定时任务 | 日志查看
# 开源地址: https://github.com/zhboner/realm
# 系统要求: CentOS 7+/Debian 9+/Ubuntu 18.04+

# ====================== 配置区域 ======================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
PLAIN="\033[0m"

CONFIG_DIR="/etc/realm"
CONFIG_FILE="$CONFIG_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
LOG_FILE="/var/log/realm.log"
CRON_FILE="/etc/cron.d/realm-manager-cron"
SCRIPT_FILE="/usr/local/bin/realm-manager"
ARCH="unknown"
LATEST_VERSION="unknown"
INSTALLED_VERSION="unknown"

# ====================== 核心函数 ======================

# 初始化环境
init_environment() {
    # 检测root权限
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误: 必须使用root用户运行此脚本!${PLAIN}"
        exit 1
    fi
    
    # 检测架构
    case "$(uname -m)" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="armv7" ;;
        *) 
            echo -e "${RED}不支持的架构: $(uname -m)${PLAIN}"
            exit 1
        ;;
    esac
    
    # 获取版本信息
    get_latest_version
    if [ -f "/usr/local/bin/realm" ]; then
        INSTALLED_VERSION=$($(which realm) -V 2>/dev/null | awk '{print $2}')
    fi
    
    # 创建必要目录
    mkdir -p "$CONFIG_DIR"
    touch "$CRON_FILE"
    
    # 安装自己为系统命令
    if [ ! -f "$SCRIPT_FILE" ]; then
        cp "$0" "$SCRIPT_FILE"
        chmod +x "$SCRIPT_FILE"
        echo -e "${GREEN}管理脚本已安装到系统命令: ${YELLOW}realm-manager${PLAIN}"
    fi
}

# 获取最新版本
get_latest_version() {
    LATEST_VERSION=$(curl -sL https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | cut -d'"' -f4)
    if [ -z "$LATEST_VERSION" ]; then
        LATEST_VERSION="v2.4.6"
        echo -e "${YELLOW}警告: 无法获取最新版本，使用默认版本 v2.4.6${PLAIN}"
    fi
}

# 显示标题
show_header() {
    clear
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}            Realm 高级管理脚本              ${PLAIN}"
    echo -e "${GREEN}                模块化设计版                ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    
    # 显示版本信息
    if [ -n "$INSTALLED_VERSION" ]; then
        echo -e "  ${CYAN}已安装版本: ${YELLOW}${INSTALLED_VERSION}${PLAIN}"
    else
        echo -e "  ${CYAN}已安装版本: ${RED}未安装${PLAIN}"
    fi
    echo -e "  ${CYAN}最新版本:    ${YELLOW}${LATEST_VERSION}${PLAIN}"
    echo -e "  ${CYAN}系统架构:    ${YELLOW}${ARCH}${PLAIN}"
    
    # 显示服务状态
    if systemctl is-active realm >/dev/null 2>&1; then
        echo -e "  ${CYAN}服务状态:   ${GREEN}运行中${PLAIN}"
    else
        echo -e "  ${CYAN}服务状态:   ${RED}未运行${PLAIN}"
    fi
    
    # 显示规则数量
    if [ -f "$CONFIG_FILE" ]; then
        RULE_COUNT=$(grep -c "\[\[endpoints\]\]" "$CONFIG_FILE")
        echo -e "  ${CYAN}转发规则:   ${YELLOW}$RULE_COUNT 条${PLAIN}"
    else
        echo -e "  ${CYAN}转发规则:   ${RED}无配置文件${PLAIN}"
    fi
    
    # 显示定时任务数量
    if [ -s "$CRON_FILE" ]; then
        CRON_COUNT=$(wc -l < "$CRON_FILE")
        echo -e "  ${CYAN}定时任务:   ${YELLOW}$CRON_COUNT 个${PLAIN}"
    else
        echo -e "  ${CYAN}定时任务:   ${YELLOW}无${PLAIN}"
    fi
    
    echo -e "${GREEN}==============================================${PLAIN}"
}

# ====================== 安装/更新模块 ======================

# 安装 Realm
install_realm() {
    echo -e "\n${BLUE}>>> 安装 Realm${PLAIN}"
    
    if [ -f "/usr/local/bin/realm" ]; then
        echo -e "${YELLOW}Realm 已安装，将更新到最新版本${PLAIN}"
    fi
    
    mkdir -p "$REALM_DIR"
    cd "$REALM_DIR" || exit 1
    
    # 获取最新版本号
    echo -e "${BLUE}▶ 正在检测最新版本...${NC}"
    LATEST_VERSION=$(curl -sL https://github.com/zhboner/realm/releases | grep -oE '/zhboner/realm/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | cut -d'/' -f6 | tr -d 'v')
    
    # 版本号验证
    if [[ -z "$LATEST_VERSION" || ! "$LATEST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "版本检测失败，使用备用版本2.7.0"
        LATEST_VERSION="2.7.0"
        echo -e "${YELLOW}⚠ 无法获取最新版本，使用备用版本 v${LATEST_VERSION}${NC}"
    else
        echo -e "${GREEN}✓ 检测到最新版本 v${LATEST_VERSION}${NC}"
    fi
    
    # 下载最新版本
    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/v${LATEST_VERSION}/realm-x86_64-unknown-linux-gnu.tar.gz"
    echo -e "${YELLOW}正在下载 Realm ${LATEST_VERSION}...${PLAIN}"
     if ! wget --show-progress -qO realm.tar.gz "$DOWNLOAD_URL"; then
        log "安装失败：下载错误"
        echo -e "${RED}✖ 文件下载失败，请检查：${NC}"
        echo -e "1. 网络连接状态"
        echo -e "2. GitHub访问权限"
        echo -e "3. 手动验证下载地址: $DOWNLOAD_URL"
        return 1
    fi
    
    # 解压安装
    tar -xzf realm.tar.gz
    chmod +x realm
    rm realm.tar.gz
    
    # 初始化配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << EOF
[log]
level = "info"
output = "$LOG_FILE"

# 在此添加转发规则
# 格式示例:
# [[endpoints]]
# listen = "0.0.0.0:8080"
# remote = "127.0.0.1:80"
EOF
        echo -e "${GREEN}配置文件已创建: ${YELLOW}$CONFIG_FILE${PLAIN}"
    fi
    
    # 创建 systemd 服务
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Realm Port Forwarding Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/realm -c $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm >/dev/null 2>&1
    
    INSTALLED_VERSION=$($(which realm) -V 2>/dev/null | awk '{print $2}')
    echo -e "${GREEN}Realm ${INSTALLED_VERSION} 安装完成!${PLAIN}"
    echo -e "配置文件: ${YELLOW}$CONFIG_FILE${PLAIN}"
    
    # 启动服务
    systemctl start realm
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}服务已成功启动${PLAIN}"
    else
        echo -e "${YELLOW}服务启动失败，请检查配置${PLAIN}"
    fi
}

# 更新 Realm
update_realm() {
    echo -e "\n${BLUE}>>> 更新 Realm${PLAIN}"
    
    if [ ! -f "/usr/local/bin/realm" ]; then
        echo -e "${YELLOW}Realm 未安装，将执行安装操作${PLAIN}"
        install_realm
        return
    fi
    
    # 获取当前版本
    CURRENT_VERSION=$($(which realm) -V 2>/dev/null | awk '{print $2}')
    
    # 检查是否需要更新
    if [ "$CURRENT_VERSION" == "$LATEST_VERSION" ]; then
        echo -e "${GREEN}当前已是最新版本 (${CURRENT_VERSION})，无需更新${PLAIN}"
        return
    fi
    
    echo -e "${YELLOW}当前版本: ${CURRENT_VERSION}${PLAIN}"
    echo -e "${YELLOW}最新版本: ${LATEST_VERSION}${PLAIN}"
    
    # 停止服务
    systemctl stop realm
    
    # 下载新版本
    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/${LATEST_VERSION}/realm-${ARCH}-unknown-linux-gnu.tar.gz"
    echo -e "${YELLOW}正在下载新版本...${PLAIN}"
    mkdir -p /tmp/realm
    curl -sL "$DOWNLOAD_URL" -o /tmp/realm.tar.gz
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败!${PLAIN}"
        systemctl start realm
        exit 1
    fi
    
    # 解压并替换
    tar xzf /tmp/realm.tar.gz -C /tmp/realm
    mv /tmp/realm/realm /usr/local/bin/realm
    chmod +x /usr/local/bin/realm
    rm -rf /tmp/realm /tmp/realm.tar.gz
    
    # 启动服务
    systemctl start realm
    
    INSTALLED_VERSION=$($(which realm) -V 2>/dev/null | awk '{print $2}')
    echo -e "${GREEN}Realm 已成功更新到 ${INSTALLED_VERSION}${PLAIN}"
    
    if systemctl is-active realm >/dev/null 2>&1; then
        echo -e "${GREEN}服务已成功启动${PLAIN}"
    else
        echo -e "${YELLOW}服务启动失败，请检查配置${PLAIN}"
        systemctl status realm --no-pager -l
    fi
}

# ====================== 规则管理模块 ======================

# 检查端口占用
check_port() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        return 1  # 端口已被占用
    fi
    return 0  # 端口可用
}

# 添加转发规则
add_rule() {
    echo -e "\n${BLUE}>>> 添加转发规则${PLAIN}"
    echo -e "${YELLOW}请选择规则类型:${PLAIN}"
    echo "1) 服务端模式 (监听公网端口转发到本地)"
    echo "2) 客户端模式 (将本地端口转发到远程服务端)"
    read -rp "请输入数字 [1-2]: " MODE_CHOICE
    
    case $MODE_CHOICE in
        1)
            while true; do
                read -rp "请输入服务端监听端口 (如: 2080): " LISTEN_PORT
                if ! [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] || [ "$LISTEN_PORT" -lt 1 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
                    echo -e "${RED}端口号无效! 请输入1-65535之间的数字${PLAIN}"
                    continue
                fi
                
                # 检查端口是否被占用
                if ! check_port "$LISTEN_PORT"; then
                    echo -e "${RED}端口 $LISTEN_PORT 已被占用!${PLAIN}"
                else
                    break
                fi
            done
            
            while true; do
                read -rp "请输入要转发的本地地址 (格式: 127.0.0.1:本地端口): " TARGET
                if ! [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]{1,5}$ ]]; then
                    echo -e "${RED}格式错误! 请使用 IP:端口 格式${PLAIN}"
                else
                    break
                fi
            done
            
            # 添加规则到配置文件
            cat >> "$CONFIG_FILE" << EOF

[[endpoints]]
listen = "0.0.0.0:$LISTEN_PORT"
remote = "$TARGET"
EOF
            ;;
        2)
            while true; do
                read -rp "请输入本地监听端口 (如: 1080): " LOCAL_PORT
                if ! [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || [ "$LOCAL_PORT" -lt 1 ] || [ "$LOCAL_PORT" -gt 65535 ]; then
                    echo -e "${RED}端口号无效! 请输入1-65535之间的数字${PLAIN}"
                    continue
                fi
                
                # 检查端口是否被占用
                if ! check_port "$LOCAL_PORT"; then
                    echo -e "${RED}端口 $LOCAL_PORT 已被占用!${PLAIN}"
                else
                    break
                fi
            done
            
            while true; do
                read -rp "请输入远程服务端地址 (格式: 服务端IP:服务端端口): " REMOTE
                if ! [[ "$REMOTE" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]{1,5}$ ]]; then
                    echo -e "${RED}格式错误! 请使用 IP:端口 格式${PLAIN}"
                else
                    break
                fi
            done
            
            # 添加规则到配置文件
            cat >> "$CONFIG_FILE" << EOF

[[endpoints]]
listen = "127.0.0.1:$LOCAL_PORT"
remote = "$REMOTE"
EOF
            ;;
        *)
            echo -e "${RED}无效选择!${PLAIN}"
            return
            ;;
    esac
    
    # 重启服务
    systemctl restart realm
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}规则添加成功! 服务已重启${PLAIN}"
    else
        echo -e "${RED}服务重启失败! 请检查配置${PLAIN}"
        systemctl status realm --no-pager -l
    fi
    
    view_rules
}

# 查看转发规则
view_rules() {
    echo -e "\n${BLUE}>>> 当前转发规则${PLAIN}"
    
    if [ ! -f "$CONFIG_FILE" ] || ! grep -q "\[\[endpoints\]\]" "$CONFIG_FILE"; then
        echo -e "${YELLOW}没有找到转发规则${PLAIN}"
        return
    fi
    
    # 提取规则并编号
    awk '/\[\[endpoints\]\]/{i++; print "\n规则 "i":"; next} 
         /listen|remote/{gsub(/"/, "", $0); print "  " $0}' "$CONFIG_FILE"
    
    # 显示服务状态
    echo -e "\n${BLUE}服务状态:${PLAIN}"
    systemctl status realm --no-pager -l | head -n 5
}

# 删除转发规则
delete_rule() {
    view_rules
    
    if [ ! -f "$CONFIG_FILE" ] || ! grep -q "\[\[endpoints\]\]" "$CONFIG_FILE"; then
        return
    fi
    
    read -rp "请输入要删除的规则编号 (0取消): " rule_num
    if [ "$rule_num" -eq 0 ] 2>/dev/null; then
        return
    fi
    
    # 计算规则数量
    rule_count=$(grep -c "\[\[endpoints\]\]" "$CONFIG_FILE")
    
    if ! [[ "$rule_num" =~ ^[0-9]+$ ]] || [ "$rule_num" -gt "$rule_count" ] || [ "$rule_num" -lt 1 ]; then
        echo -e "${RED}无效的规则编号!${PLAIN}"
        return
    fi
    
    # 创建临时文件
    tmp_file=$(mktemp)
    
    # 使用 awk 删除指定规则
    awk -v rule_num="$rule_num" '
        /\[\[endpoints\]\]/ {
            count++
            if (count == rule_num) {
                skip = 1
                next
            }
        }
        skip && /listen|remote/ { next }
        /^$/ && skip { skip = 0; next }
        !skip { print }
    ' "$CONFIG_FILE" > "$tmp_file"
    
    # 替换配置文件
    mv "$tmp_file" "$CONFIG_FILE"
    
    # 重启服务
    systemctl restart realm
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}规则 #$rule_num 已删除! 服务已重启${PLAIN}"
    else
        echo -e "${RED}服务重启失败! 请检查配置${PLAIN}"
        systemctl status realm --no-pager -l
    fi
    
    view_rules
}

# ====================== 服务管理模块 ======================

# 服务控制
service_control() {
    echo -e "\n${BLUE}>>> 服务控制${PLAIN}"
    echo "1) 启动服务"
    echo "2) 停止服务"
    echo "3) 重启服务"
    echo "4) 查看服务状态"
    echo "0) 返回"
    
    read -rp "请选择操作: " choice
    case $choice in
        1) 
            systemctl start realm
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}服务已成功启动${PLAIN}"
            else
                echo -e "${RED}服务启动失败!${PLAIN}"
                systemctl status realm --no-pager -l
            fi
            ;;
        2) 
            systemctl stop realm
            if [ $? -eq 0 ]; then
                echo -e "${YELLOW}服务已停止${PLAIN}"
            else
                echo -e "${RED}服务停止失败!${PLAIN}"
            fi
            ;;
        3) 
            systemctl restart realm
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}服务已重启${PLAIN}"
            else
                echo -e "${RED}服务重启失败!${PLAIN}"
                systemctl status realm --no-pager -l
            fi
            ;;
        4) 
            systemctl status realm --no-pager -l
            ;;
        0) 
            return 
            ;;
        *) 
            echo -e "${RED}无效选择!${PLAIN}" 
            ;;
    esac
}

# 日志管理
log_management() {
    echo -e "\n${BLUE}>>> 日志管理${PLAIN}"
    echo "1) 实时查看日志 (Ctrl+C 退出)"
    echo "2) 查看最近日志 (100行)"
    echo "3) 清空日志文件"
    echo "0) 返回"
    
    read -rp "请选择操作: " choice
    case $choice in
        1) 
            echo -e "${CYAN}开始实时日志 (Ctrl+C 退出)...${PLAIN}"
            journalctl -u realm -f
            ;;
        2) 
            echo -e "${CYAN}最近100行日志:${PLAIN}"
            journalctl -u realm --no-pager -n 100
            ;;
        3) 
            read -rp "确定要清空日志文件? [y/N]: " confirm
            if [[ $confirm =~ ^[Yy]$ ]]; then
                > $LOG_FILE
                echo -e "${GREEN}日志已清空${PLAIN}"
            else
                echo -e "${YELLOW}取消操作${PLAIN}"
            fi
            ;;
        0) 
            return 
            ;;
        *) 
            echo -e "${RED}无效选择!${PLAIN}" 
            ;;
    esac
}

# ====================== 定时任务模块 ======================

# 定时任务管理
cron_management() {
    echo -e "\n${BLUE}>>> 定时任务管理${PLAIN}"
    echo "1) 添加定时重启任务"
    echo "2) 添加定时更新任务"
    echo "3) 查看当前定时任务"
    echo "4) 删除所有定时任务"
    echo "0) 返回"
    
    read -rp "请选择操作: " choice
    case $choice in
        1)
            echo -e "\n${CYAN}添加定时重启任务${PLAIN}"
            echo -e "示例: 每天凌晨3点重启: ${YELLOW}0 3 * * *${PLAIN}"
            echo -e "请使用cron格式输入时间 (分 时 日 月 周)"
            read -rp "请输入cron时间表达式: " cron_time
            
            # 验证cron格式
            if [[ ! "$cron_time" =~ ^[0-9*\/,-]+\ [0-9*\/,-]+\ [0-9*\/,-]+\ [0-9*\/,-]+\ [0-9*\/,-]+$ ]]; then
                echo -e "${RED}无效的cron表达式!${PLAIN}"
                return
            fi
            
            # 添加定时任务
            echo "$cron_time root systemctl restart realm" >> $CRON_FILE
            echo -e "${GREEN}定时重启任务已添加!${PLAIN}"
            ;;
        2)
            echo -e "\n${CYAN}添加定时更新任务${PLAIN}"
            echo -e "示例: 每周一凌晨2点更新: ${YELLOW}0 2 * * 1${PLAIN}"
            echo -e "请使用cron格式输入时间 (分 时 日 月 周)"
            read -rp "请输入cron时间表达式: " cron_time
            
            # 验证cron格式
            if [[ ! "$cron_time" =~ ^[0-9*\/,-]+\ [0-9*\/,-]+\ [0-9*\/,-]+\ [0-9*\/,-]+\ [0-9*\/,-]+$ ]]; then
                echo -e "${RED}无效的cron表达式!${PLAIN}"
                return
            fi
            
            # 添加定时任务
            echo "$cron_time root $SCRIPT_FILE --update" >> $CRON_FILE
            echo -e "${GREEN}定时更新任务已添加!${PLAIN}"
            ;;
        3)
            echo -e "\n${CYAN}当前定时任务:${PLAIN}"
            if [ -f "$CRON_FILE" ] && [ -s "$CRON_FILE" ]; then
                cat $CRON_FILE
            else
                echo -e "${YELLOW}没有定时任务${PLAIN}"
            fi
            ;;
        4)
            read -rp "确定要删除所有定时任务? [y/N]: " confirm
            if [[ $confirm =~ ^[Yy]$ ]]; then
                > $CRON_FILE
                echo -e "${GREEN}所有定时任务已删除!${PLAIN}"
            else
                echo -e "${YELLOW}取消操作${PLAIN}"
            fi
            ;;
        0) 
            return 
            ;;
        *) 
            echo -e "${RED}无效选择!${PLAIN}" 
            ;;
    esac
}

# ====================== 系统管理模块 ======================

# 卸载 Realm
uninstall_realm() {
    echo -e "\n${RED}>>> 卸载 Realm${PLAIN}"
    read -rp "确定要卸载 Realm? [y/N]: " confirm
    [[ ! $confirm =~ ^[Yy]$ ]] && return
    
    # 停止服务
    systemctl stop realm >/dev/null 2>&1
    systemctl disable realm >/dev/null 2>&1
    
    # 删除主程序
    rm -f /usr/local/bin/realm
    
    # 删除服务文件
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    
    # 删除定时任务
    rm -f "$CRON_FILE"
    
    # 提示用户选择删除配置和日志
    echo -e "${YELLOW}是否删除配置文件?${PLAIN}"
    read -rp "删除配置目录 $CONFIG_DIR? [y/N]: " del_config
    if [[ $del_config =~ ^[Yy]$ ]]; then
        rm -rf "$CONFIG_DIR"
    fi
    
    echo -e "${YELLOW}是否删除日志文件?${PLAIN}"
    read -rp "删除日志文件 $LOG_FILE? [y/N]: " del_log
    if [[ $del_log =~ ^[Yy]$ ]]; then
        rm -f "$LOG_FILE"
    fi
    
    # 删除管理脚本
    rm -f "$SCRIPT_FILE"
    
    echo -e "${GREEN}Realm 已完全卸载${PLAIN}"
    echo -e "感谢使用，再见!"
    exit 0
}

# ====================== 主菜单模块 ======================

# 显示主菜单
show_menu() {
    echo -e "${MAGENTA}主菜单:${PLAIN}"
    echo "1) 安装 Realm"
    echo "2) 更新 Realm"
    echo "3) 添加转发规则"
    echo "4) 查看转发规则"
    echo "5) 删除转发规则"
    echo "6) 服务控制 (启动/停止/重启)"
    echo "7) 日志管理"
    echo "8) 定时任务管理"
    echo "9) 完全卸载 Realm"
    echo "0) 退出脚本"
    echo -e "${GREEN}==============================================${PLAIN}"
}

# 主循环
main_loop() {
    while true; do
        show_header
        show_menu
        read -rp "请输入选项 [0-9]: " choice
        
        case $choice in
            1) install_realm ;;
            2) update_realm ;;
            3) add_rule ;;
            4) view_rules ;;
            5) delete_rule ;;
            6) service_control ;;
            7) log_management ;;
            8) cron_management ;;
            9) uninstall_realm ;;
            0) 
                echo -e "${GREEN}已退出脚本${PLAIN}"
                exit 0 
                ;;
            *) 
                echo -e "${RED}无效选项!${PLAIN}" 
                ;;
        esac
        
        echo -e "\n${YELLOW}按回车键返回主菜单...${PLAIN}"
        read -s
    done
}

# ====================== 脚本入口 ======================

# 处理命令行参数
if [ "$1" == "--install" ]; then
    init_environment
    install_realm
    exit 0
elif [ "$1" == "--update" ]; then
    init_environment
    update_realm
    exit 0
elif [ "$1" == "--add-rule" ]; then
    init_environment
    add_rule
    exit 0
fi

# 主程序入口
init_environment
main_loop
