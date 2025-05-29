#!/bin/bash
# Realm 一站式管理脚本
# 文件名：realm.sh
# 功能：安装/更新、规则管理、服务控制、日志查看、定时任务、卸载

CONFIG_DIR="/etc/realm"
CONF_D_DIR="$CONFIG_DIR/conf.d"
BIN_PATH="/usr/local/bin/realm"
SERVICE_PATH="/etc/systemd/system/realm.service"
LOG_PATH="/var/log/realm.log"
TMP_CONFIG="/tmp/realm_combined.toml"

check_root() {
    [ "$(id -u)" != "0" ] && echo "错误：必须使用root权限运行！" && exit 1
}

init_dirs() {
    mkdir -p "$CONF_D_DIR" && chmod 700 "$CONFIG_DIR"
}

generate_base_config() {
    [ ! -f "$CONFIG_DIR/base.toml" ] && cat > "$CONFIG_DIR/base.toml" << EOF
[log]
level = "warn"
output = "$LOG_PATH"

[network]
use_udp = true
EOF
}

generate_service() {
    cat > "$SERVICE_PATH" << EOF
[Unit]
Description=Realm Relay Service
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/rm -f $TMP_CONFIG
ExecStart=$BIN_PATH -c $TMP_CONFIG
ExecReload=/bin/kill -HUP \$MAINPID
ExecStop=/bin/kill -QUIT \$MAINPID
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

build_realm() {
    local temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT

    echo "编译安装Realm..."
    git clone https://github.com/zhboner/realm "$temp_dir"
    cd "$temp_dir" && RUSTFLAGS='-C target_cpu=native' \
    cargo build --release --features "proxy balance transport batched-udp"
    
    [ $? -eq 0 ] && cp target/release/realm "$BIN_PATH" || exit 1
}

install() {
    check_root
    apt-get install -y curl jq build-essential
    [ ! -x "$(command -v cargo)" ] && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source $HOME/.cargo/env

    build_realm
    init_dirs
    generate_base_config
    generate_service
    systemctl daemon-reload
    echo "安装完成！执行脚本启动服务"
}

rule_manage() {
    case $1 in
        add)
            read -p "监听地址 (IP:端口): " listen
            read -p "远程地址 (IP:端口): " remote
            cat > "$CONF_D_DIR/rule_$(date +%s).toml" << EOF
[[endpoints]]
listen = "$listen"
remote = "$remote"
EOF
            ;;
        list)
            grep -Hn 'listen =\|remote =' "$CONF_D_DIR"/*.toml
            ;;
        del)
            ls "$CONF_D_DIR" && read -p "删除规则文件: " f
            rm -f "$CONF_D_DIR/$f"
            ;;
    esac
}

service_ctl() {
    systemctl $1 realm
}

log_view() {
    [ -f "$LOG_PATH" ] && tail -f "$LOG_PATH" || echo "日志文件不存在"
}

cron_task() {
    case $1 in
        add)
            read -p "定时表达式 (crontab格式): " cron_exp
            (crontab -l; echo "$cron_exp $BIN_PATH -c $TMP_CONFIG") | crontab -
            ;;
        del)
            crontab -l | grep -v "$BIN_PATH" | crontab -
            ;;
    esac
}

uninstall() {
    systemctl stop realm
    rm -rf "$CONFIG_DIR" "$BIN_PATH" "$SERVICE_PATH"
    crontab -l | grep -v realm | crontab -
    echo "卸载完成"
}

menu() {
    clear
    echo "REALM 管理脚本"
    echo "------------------------"
    echo "1) 安装/更新"
    echo "2) 添加规则"
    echo "3) 列出规则"
    echo "4) 删除规则"
    echo "5) 启动服务"
    echo "6) 停止服务"
    echo "7) 查看日志"
    echo "8) 定时任务"
    echo "9) 完全卸载"
    echo "0) 退出"
    echo "------------------------"
}

while true; do
    menu
    read -p "请选择: " opt
    case $opt in
        1) install ;;
        2) rule_manage add ;;
        3) rule_manage list ;;
        4) rule_manage del ;;
        5) service_ctl start ;;
        6) service_ctl stop ;;
        7) log_view ;;
        8) cron_task add ;;
        9) uninstall ;;
        0) exit ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
    read -n 1 -p "按任意键继续..."
done
