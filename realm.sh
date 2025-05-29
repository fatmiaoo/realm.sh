#!/bin/bash

# 全局配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'
INSTALL_DIR="/etc/realm"
CONFIG_FILE="$INSTALL_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
CRON_JOB="0 3 * * * /bin/bash $PWD/$(basename $0) --cron"

# 依赖检查
check_dependencies() {
    command -v wget >/dev/null 2>&1 || { echo -e "${RED}需要安装 wget${NC}"; exit 1; }
    command -v curl >/dev/null 2>&1 || { echo -e "${RED}需要安装 curl${NC}"; exit 1; }
    command -v systemctl >/dev/null 2>&1 || { echo -e "${RED}需要 systemd 支持${NC}"; exit 1; }
}

# 检查root
check_root() {
    [ "$EUID" -ne 0 ] && { echo -e "${RED}必须使用root权限运行！${NC}"; exit 1; }
}

# 安装状态
check_installed() {
    [ -f "$INSTALL_DIR/realm" ] && return 0 || return 1
}

# 版本信息
get_current_version() {
    check_installed && $INSTALL_DIR/realm -v | awk '{print $2}' || echo "未安装"
}

get_latest_version() {
    curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep tag_name | cut -d'"' -f4
}

# 更新检查
check_update() {
    check_installed || return
    current=$(get_current_version)
    latest=$(get_latest_version)
    [ "$current" != "$latest" ] && return 0 || return 1
}

# 安装/更新
install_realm() {
    check_dependencies
    latest=$(get_latest_version)
    url="https://github.com/zhboner/realm/releases/download/$latest/realm-x86_64-unknown-linux-gnu.tar.gz"
    
    echo -e "${BLUE}▶ 正在安装 realm v$latest...${NC}"
    mkdir -p $INSTALL_DIR
    wget -qO- $url | tar xz -C $INSTALL_DIR
    
    # 初始化配置
    if [ ! -f $CONFIG_FILE ]; then
        cat > $CONFIG_FILE << EOF
[network]
use_udp = true
no_tcp = false
EOF
    fi
    
    # 创建服务
    cat > $SERVICE_FILE << EOF
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
    
    systemctl daemon-reload
    systemctl enable --now realm >/dev/null 2>&1
    echo -e "${GREEN}✔ 安装成功，服务已启动${NC}"
}

# 转发规则管理
add_rule() {
    read -p "监听地址 (格式: IP:端口): " listen
    read -p "目标地址 (格式: IP:端口): " remote
    
    if ! [[ $listen =~ ^[0-9.]+:[0-9]+$ ]] || ! [[ $remote =~ ^[0-9.]+:[0-9]+$ ]]; then
        echo -e "${RED}错误：地址格式无效${NC}"
        return
    fi
    
    cat >> $CONFIG_FILE << EOF

[[endpoints]]
listen = "$listen"
remote = "$remote"
EOF
    systemctl restart realm
    echo -e "${GREEN}✔ 规则添加成功${NC}"
}

list_rules() {
    awk '/\[\[endpoints\]\]/{flag=1;next} /^$/{flag=0} flag' $CONFIG_FILE | 
    awk -F'"' 'BEGIN{print "编号\t监听地址\t\t目标地址";i=0}
    /listen/{l=$2; i++} 
    /remote/{printf "%d\t%-15s\t%s\n",i,l,$2}'
}

delete_rule() {
    list_rules
    read -p "输入要删除的规则编号: " num
    total=$(grep -c '\[\[endpoints\]\]' $CONFIG_FILE)
    
    if [ "$num" -gt 0 -a "$num" -le $total ] 2>/dev/null; then
        start=$(grep -n '\[\[endpoints\]\]' $CONFIG_FILE | sed -n ${num}p | cut -d: -f1)
        end=$(($start + 2))
        sed -i "${start},${end}d" $CONFIG_FILE
        systemctl restart realm
        echo -e "${GREEN}✔ 规则删除成功${NC}"
    else
        echo -e "${RED}错误：无效的编号${NC}"
    fi
}

# 服务管理
service_management() {
    echo -e "\n1. 启动服务\n2. 停止服务\n3. 重启服务"
    read -p "选择操作 [1-3]: " action
    case $action in
        1) systemctl start realm ;;
        2) systemctl stop realm ;;
        3) systemctl restart realm ;;
        *) echo -e "${RED}无效选择${NC}"; return ;;
    esac
    echo -e "${GREEN}操作完成！当前状态: $(systemctl is-active realm)${NC}"
}

# 日志查看
view_logs() {
    journalctl -u realm.service -f -n 50
}

# 定时任务
cron_management() {
    echo -e "1. 添加每日自动更新\n2. 移除定时任务"
    read -p "选择操作: " opt
    case $opt in
        1) (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab - ;;
        2) crontab -l | grep -v "$CRON_JOB" | crontab - ;;
        *) echo -e "${RED}无效选择${NC}"; return ;;
    esac
    echo -e "${GREEN}定时任务已更新！当前任务列表:${NC}"
    crontab -l
}

# 卸载
uninstall_realm() {
    systemctl stop realm >/dev/null 2>&1
    systemctl disable realm >/dev/null 2>&1
    rm -rf $INSTALL_DIR $SERVICE_FILE
    echo -e "${YELLOW}✔ Realm 已卸载${NC}"
}

# 主界面
show_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════╗"
    echo -e "║         Realm 管理器        ║"
    echo -e "╠════════════════════════════╣"
    echo -e "║ 版本状态: $(printf "%-24s" "$(get_current_version)") ║"
    echo -e "║ 最新版本: $(printf "%-24s" "$(get_latest_version)") ║"
    echo -e "╚════════════════════════════╝${NC}"
    echo -e "\n1. 安装/更新 Realm\n2. 管理转发规则\n3. 服务控制\n4. 查看日志\n5. 定时任务\n6. 卸载\n0. 退出"
}

# 执行入口
check_root
case $1 in
    --cron)
        check_update && install_realm
        ;;
    *)
        while :; do
            show_menu
            check_update && echo -e "${YELLOW}提示：发现可用更新！${NC}"
            read -p "请输入选项: " choice
            
            case $choice in
                1) install_realm ;;
                2) 
                    echo -e "\na. 添加规则\nb. 查看规则\nc. 删除规则"
                    read -p "选择操作: " sub
                    case $sub in
                        a) add_rule ;;
                        b) list_rules ;;
                        c) delete_rule ;;
                        *) echo -e "${RED}无效选择${NC}" ;;
                    esac
                    ;;
                3) service_management ;;
                4) view_logs ;;
                5) cron_management ;;
                6) uninstall_realm ;;
                0) exit 0 ;;
                *) echo -e "${RED}无效选项！${NC}" ;;
            esac
            read -p "按回车返回主菜单..."
        done
        ;;
esac
