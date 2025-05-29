#!/bin/bash

# Realm Management Script for Debian 11
# Version: 1.0
# Author: Your Name

# 颜色定义
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
RESET='\e[0m'

# 路径配置
INSTALL_DIR="/etc/realm"
CONFIG_FILE="$INSTALL_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
VERSION_FILE="$INSTALL_DIR/version"

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用root权限运行此脚本!${RESET}"
        exit 1
    fi
}

# 检查最新版本
check_latest_version() {
    LATEST_VERSION=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep 'tag_name' | cut -d\" -f4)
    echo $LATEST_VERSION
}

# 获取已安装版本
get_installed_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        echo "未安装"
    fi
}

# 显示状态
show_status() {
    INSTALLED_VER=$(get_installed_version)
    LATEST_VER=$(check_latest_version)
    
    echo -e "${BLUE}当前状态:${RESET}"
    echo -e "已安装版本: ${GREEN}$INSTALLED_VER${RESET}"
    echo -e "最新版本:    ${YELLOW}$LATEST_VER${RESET}"
    echo -e "服务状态:    $(systemctl is-active realm.service 2>/dev/null || echo '未安装')"
    echo "----------------------------------------"
}

# 安装依赖
install_dependencies() {
    apt update
    apt install -y curl wget tar
}

# 安装/更新Realm
install_realm() {
    VERSION=$(check_latest_version)
    echo -e "${YELLOW}正在安装/更新 Realm v$VERSION...${RESET}"
    
    mkdir -p "$INSTALL_DIR"
    wget -qO- "https://github.com/zhboner/realm/releases/download/$VERSION/realm-x86_64-unknown-linux-gnu.tar.gz" | \
    tar xz -C "$INSTALL_DIR"
    
    # 创建配置文件模板
    cat > "$CONFIG_FILE" << EOF
[network]
use_udp = true
no_tcp = false
EOF

    # 创建服务文件
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Realm Service
After=network.target

[Service]
ExecStart=$INSTALL_DIR/realm -c $CONFIG_FILE
WorkingDirectory=$INSTALL_DIR
Restart=always
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    # 记录版本
    echo "$VERSION" > "$VERSION_FILE"
    
    systemctl daemon-reload
    systemctl enable realm.service
    echo -e "${GREEN}安装完成!${RESET}"
}

# 添加转发规则
add_rule() {
    read -p "输入监听地址 (格式: IP:端口): " listen
    read -p "输入远程地址 (格式: IP:端口): " remote
    
    # 验证输入格式
    if ! [[ "$listen" =~ ^[0-9.]+:[0-9]+$ ]] || ! [[ "$remote" =~ ^[0-9.]+:[0-9]+$ ]]; then
        echo -e "${RED}错误: 地址格式不正确!${RESET}"
        return
    fi
    
    cat >> "$CONFIG_FILE" << EOF

[[endpoints]]
listen = "$listen"
remote = "$remote"
EOF

    echo -e "${GREEN}规则添加成功!${RESET}"
    restart_service
}

# 显示规则
show_rules() {
    echo -e "${BLUE}当前转发规则:${RESET}"
    awk '/\[\[endpoints\]\]/{flag=1;print NR")";next} flag&&/listen/{print "  监听:",$3;next} flag&&/remote/{print "  远程:",$3;flag=0}' "$CONFIG_FILE"
}

# 删除规则
delete_rule() {
    show_rules
    read -p "输入要删除的规则编号: " num
    
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}无效的输入!${RESET}"
        return
    fi
    
    start_line=$(awk "/\[\[endpoints\]\]/{n++}n==$num{print NR; exit}" "$CONFIG_FILE")
    if [ -z "$start_line" ]; then
        echo -e "${RED}规则不存在!${RESET}"
        return
    fi
    
    end_line=$(awk -v start="$start_line" 'NR>=start && /^$/ {print NR; exit}' "$CONFIG_FILE")
    sed -i "${start_line},${end_line}d" "$CONFIG_FILE"
    
    echo -e "${GREEN}规则删除成功!${RESET}"
    restart_service
}

# 服务管理
restart_service() {
    systemctl restart realm.service
    echo -e "${GREEN}服务已重启${RESET}"
}

start_service() {
    systemctl start realm.service
}

stop_service() {
    systemctl stop realm.service
}

# 卸载
uninstall() {
    echo -e "${RED}正在卸载Realm...${RESET}"
    systemctl stop realm.service
    systemctl disable realm.service
    rm -rf "$INSTALL_DIR" "$SERVICE_FILE"
    echo -e "${GREEN}卸载完成!${RESET}"
}

# 显示菜单
show_menu() {
    clear
    show_status
    echo -e "${BLUE}请选择操作:${RESET}"
    echo "1) 安装/更新 Realm"
    echo "2) 添加转发规则"
    echo "3) 查看转发规则"
    echo "4) 删除转发规则"
    echo "5) 启动服务"
    echo "6) 停止服务"
    echo "7) 重启服务"
    echo "8) 查看日志"
    echo "9) 卸载 Realm"
    echo "0) 退出"
    echo
}

# 主循环
main() {
    check_root
    install_dependencies
    
    while true; do
        show_menu
        read -p "请输入选项: " choice
        
        case $choice in
            1) install_realm ;;
            2) add_rule ;;
            3) show_rules ;;
            4) delete_rule ;;
            5) start_service ;;
            6) stop_service ;;
            7) restart_service ;;
            8) journalctl -u realm.service -f ;;
            9) uninstall ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项!${RESET}" ;;
        esac
        
        read -p "按回车键继续..."
    done
}

# 启动脚本
main
