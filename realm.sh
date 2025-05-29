#!/bin/bash

# ========== 配置 ==========
REALM_DIR="/etc/realm"
REALM_BIN="$REALM_DIR/realm"
CONFIG="$REALM_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
REPO="zhboner/realm"
ARCH="x86_64-unknown-linux-gnu"
CRON_FILE="/etc/cron.d/realm_auto_update"
COLOR_TITLE="\033[1;36m"
COLOR_ITEM="\033[1;32m"
COLOR_ERR="\033[1;31m"
COLOR_INFO="\033[1;33m"
NC="\033[0m"

# ========== 公共函数 ==========
title() {
    echo -e "\n${COLOR_TITLE}========== $1 ==========${NC}\n"
}

info() {
    echo -e "${COLOR_INFO}$1${NC}"
}

success() {
    echo -e "${COLOR_ITEM}$1${NC}"
}

error() {
    echo -e "${COLOR_ERR}$1${NC}"
}

pause() {
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

get_latest_version() {
    curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep -oP '"tag_name": "\K(.*)(?=")'
}

get_installed_version() {
    [ -f "$REALM_BIN" ] && "$REALM_BIN" -v 2>/dev/null | grep -oP "v[0-9]+\.[0-9]+\.[0-9]+" || echo "未安装"
}

is_installed() {
    [ -f "$REALM_BIN" ]
}

# ========== 安装/更新 ==========
install_realm() {
    title "安装/更新 Realm"
    latest=$(get_latest_version)
    installed=$(get_installed_version)

    if [ "$installed" == "$latest" ]; then
        success "Realm 已是最新版本 $latest"
        pause; return
    fi

    mkdir -p "$REALM_DIR"
    url="https://github.com/$REPO/releases/download/$latest/realm-$ARCH.tar.gz"
    info "下载 Realm $latest ..."
    wget -qO "$REALM_DIR/realm.tar.gz" "$url" || { error "下载失败！"; pause; return; }
    tar -zxvf "$REALM_DIR/realm.tar.gz" -C "$REALM_DIR" || { error "解压失败！"; pause; return; }
    chmod +x "$REALM_BIN"
    rm -f "$REALM_DIR/realm.tar.gz"
    success "Realm $latest 安装成功！"
    setup_service
    pause
}

setup_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm Service
After=network.target

[Service]
ExecStart=$REALM_BIN -c $CONFIG
WorkingDirectory=$REALM_DIR
Restart=always
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable realm.service
}

# ========== 配置规则 ==========
add_rule() {
    title "添加转发规则"
    read -p "本地监听端口 (如 0.0.0.0:23456): " listen
    read -p "远程目标 (如 1.2.3.4:23456): " remote

    if ! grep -q "endpoints" "$CONFIG" 2>/dev/null; then
        cat > "$CONFIG" <<EOF
[network]
use_udp = true
no_tcp = false

[[endpoints]]
listen = "$listen"
remote = "$remote"
EOF
    else
        cat >> "$CONFIG" <<EOF

[[endpoints]]
listen = "$listen"
remote = "$remote"
EOF
    fi
    success "已添加转发规则: $listen -> $remote"
    systemctl restart realm.service
    pause
}

list_rules() {
    title "查看转发规则"
    if [ -f "$CONFIG" ]; then
        grep -E "listen|remote" "$CONFIG"
    else
        error "未找到配置文件！"
    fi
    pause
}

delete_rule() {
    title "删除转发规则"
    list_rules
    read -p "输入要删除的本地监听端口 (如 0.0.0.0:23456): " del_port
    if grep -q "$del_port" "$CONFIG"; then
        # 删除该规则块
        sed -i "/listen = \"$del_port\"/,/remote = \".*\"/d" "$CONFIG"
        success "已删除规则 $del_port"
        systemctl restart realm.service
    else
        error "未找到该规则！"
    fi
    pause
}

# ========== 服务管理 ==========
start_service() {
    title "启动 Realm 服务"
    systemctl start realm.service
    success "服务已启动"
    pause
}

stop_service() {
    title "停止 Realm 服务"
    systemctl stop realm.service
    success "服务已停止"
    pause
}

restart_service() {
    title "重启 Realm 服务"
    systemctl restart realm.service
    success "服务已重启"
    pause
}

show_log() {
    title "查看 Realm 日志"
    journalctl -u realm.service -n 50 --no-pager
    pause
}

# ========== 定时任务管理 ==========
cron_menu() {
    title "定时任务管理"
    echo -e "${COLOR_ITEM}1. 添加每日自动更新"
    echo -e "2. 移除自动更新"
    echo -e "3. 返回主菜单${NC}"
    read -p "请选择: " c
    case "$c" in
        1)
            echo "0 5 * * * root bash $(realpath $0) --auto-update > /dev/null 2>&1" > $CRON_FILE
            success "已添加每日自动自动更新任务 (凌晨5点)"
            ;;
        2)
            rm -f $CRON_FILE
            success "已移除自动更新任务"
            ;;
        *) ;;
    esac
    pause
}

auto_update() {
    latest=$(get_latest_version)
    installed=$(get_installed_version)
    if [ "$installed" != "$latest" ]; then
        install_realm
        systemctl restart realm.service
    fi
}

# ========== 卸载 ==========
uninstall_realm() {
    title "卸载 Realm"
    systemctl stop realm.service
    systemctl disable realm.service
    rm -f "$REALM_BIN"
    rm -f "$CONFIG"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -f "$CRON_FILE"
    success "Realm 已卸载"
    pause
}

# ========== 主菜单 ==========
main_menu() {
    while true; do
        clear
        echo -e "${COLOR_TITLE}======== Realm 一键管理脚本（Debian）========${NC}"
        echo -e "${COLOR_ITEM}1. 安装/更新 Realm"
        echo "2. 添加转发规则"
        echo "3. 查看转发规则"
        echo "4. 删除转发规则"
        echo "5. 启动服务"
        echo "6. 停止服务"
        echo "7. 重启服务"
        echo "8. 查看日志"
        echo "9. 定时任务管理"
        echo "10. 卸载 Realm"
        echo "0. 退出脚本${NC}"
        latest=$(get_latest_version)
        installed=$(get_installed_version)
        echo -e "\n${COLOR_INFO}已安装版本: $installed  |  最新版本: $latest${NC}\n"
        read -p "请选择: " n
        case "$n" in
            1) install_realm ;;
            2) add_rule ;;
            3) list_rules ;;
            4) delete_rule ;;
            5) start_service ;;
            6) stop_service ;;
            7) restart_service ;;
            8) show_log ;;
            9) cron_menu ;;
            10) uninstall_realm ;;
            0) exit 0 ;;
            *) error "请输入正确的选项！"; sleep 1 ;;
        esac
    done
}

# ========== 命令行参数处理 ==========
if [[ "$1" == "--auto-update" ]]; then
    auto_update
    exit 0
fi

main_menu
