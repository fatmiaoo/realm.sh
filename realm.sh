#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 配置
SCRIPT_VERSION="1.2.0"
REALM_CONFIG="/etc/realm/config.json"
SCRIPT_PATH=$(realpath "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
LOG_FILE="/var/log/realm_installer.log"

# 日志函数
log_info() {
    local message="$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1"
    echo -e "${GREEN}${message}${NC}"
    echo "$message" >> "$LOG_FILE"
}

log_warn() {
    local message="$(date '+%Y-%m-%d %H:%M:%S') [WARN] $1"
    echo -e "${YELLOW}${message}${NC}"
    echo "$message" >> "$LOG_FILE"
}

log_error() {
    local message="$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1"
    echo -e "${RED}${message}${NC}"
    echo "$message" >> "$LOG_FILE"
}

# 检查系统
check_system() {
    log_info "检查系统环境..."
    if [[ -f /etc/redhat-release ]]; then
        OS="centos"
        PACKAGE_MANAGER="yum"
    elif [[ -f /etc/debian_version ]]; then
        OS="debian"
        PACKAGE_MANAGER="apt-get"
    elif [[ -f /etc/arch-release ]]; then
        OS="arch"
        PACKAGE_MANAGER="pacman"
    else
        log_error "不支持的系统"
        exit 1
    fi
    
    # 检查是否为root用户
    if [[ $(id -u) -ne 0 ]]; then
        log_error "请使用root用户运行此脚本"
        exit 1
    fi
    
    log_info "系统: $OS"
}

# 安装依赖
install_dependencies() {
    log_info "安装依赖..."
    
    case $OS in
        centos)
            $PACKAGE_MANAGER update -y
            $PACKAGE_MANAGER install -y wget curl unzip tar jq
            ;;
        debian)
            $PACKAGE_MANAGER update -y
            $PACKAGE_MANAGER install -y wget curl unzip tar jq
            ;;
        arch)
            $PACKAGE_MANAGER -Syu --noconfirm wget curl unzip tar jq
            ;;
    esac
    
    log_info "依赖安装完成"
}

# 安装Realm
install_realm() {
    log_info "开始安装Realm..."
    
    # 创建目录
    mkdir -p /opt/realm
    cd /opt/realm
    
    # 获取最新版本
    log_info "获取Realm最新版本..."
    VERSION=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep "tag_name" | cut -d '"' -f 4 | sed 's/v//')
    
    if [ -z "$VERSION" ]; then
        log_error "无法获取最新版本信息，使用默认版本"
        VERSION="0.11.1"
    fi
    
    log_info "最新版本: $VERSION"
    
    # 检查是否已安装
    if command -v realm &> /dev/null; then
        CURRENT_VERSION=$(realm -v | awk '{print $2}')
        log_info "已安装Realm版本: $CURRENT_VERSION"
        
        if [[ "$CURRENT_VERSION" == "$VERSION" ]]; then
            log_info "已是最新版本，无需更新"
            cd ~
            rm -rf /opt/realm
            return
        else
            log_warn "将从 $CURRENT_VERSION 更新到 $VERSION"
            systemctl stop realm
        fi
    fi
    
    # 下载Realm
    log_info "下载Realm $VERSION..."
    wget https://github.com/zhboner/realm/releases/download/v$VERSION/realm-linux-amd64.zip -O realm.zip
    
    if [ ! -f "realm.zip" ]; then
        log_error "下载失败，请检查网络连接"
        cd ~
        rm -rf /opt/realm
        exit 1
    fi
    
    # 解压
    log_info "解压文件..."
    unzip -o realm.zip
    chmod +x realm
    
    # 移动到bin目录
    mv -f realm /usr/local/bin/
    
    # 清理
    cd ~
    rm -rf /opt/realm
    
    log_info "Realm $VERSION 安装/更新完成"
}

# 配置Realm
configure_realm() {
    log_info "配置Realm..."
    
    # 创建配置目录
    mkdir -p /etc/realm
    cd /etc/realm
    
    # 如果配置文件不存在，创建它
    if [ ! -f "$REALM_CONFIG" ]; then
        log_info "创建配置文件..."
        wget https://raw.githubusercontent.com/zhboner/realm/master/config.example.json -O "$REALM_CONFIG" || touch "$REALM_CONFIG"
        
        # 添加默认配置
        if [ -s "$REALM_CONFIG" ]; then
            log_info "使用示例配置文件"
        else
            log_info "创建空配置文件"
            cat > "$REALM_CONFIG" << EOF
{
  "log": {
    "level": "info",
    "output": "/var/log/realm.log"
  },
  "servers": []
}
EOF
        fi
    else
        log_info "配置文件已存在，跳过创建"
    fi
    
    # 配置systemd服务
    log_info "配置systemd服务..."
    cat > /etc/systemd/system/realm.service << EOF
[Unit]
Description=Realm Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c /etc/realm/config.json
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    
    # 重载systemd
    systemctl daemon-reload
    
    log_info "Realm配置完成"
}

# 添加转发规则
add_forward_rule() {
    log_info "添加转发规则..."
    
    read -p "请输入本地监听地址 (例如: 0.0.0.0:8080): " listen
    read -p "请输入远程目标地址 (例如: 1.1.1.1:443): " remote
    read -p "请输入规则名称 (可选): " name
    
    if [ -z "$listen" ] || [ -z "$remote" ]; then
        log_error "监听地址和远程地址不能为空"
        return 1
    fi
    
    if [ -z "$name" ]; then
        name="rule_$(date +%s)"
    fi
    
    # 创建规则JSON
    rule=$(cat << EOF
{
  "name": "$name",
  "listen": "$listen",
  "remote": "$remote"
}
EOF
)
    
    # 添加到配置文件
    if ! jq -e '.servers += ['"$rule"']' "$REALM_CONFIG" > /tmp/config.json; then
        log_error "添加规则失败，可能是配置文件格式错误"
        return 1
    fi
    
    mv /tmp/config.json "$REALM_CONFIG"
    log_info "成功添加转发规则: $name"
    log_info "监听: $listen -> 远程: $remote"
    
    # 重启服务使配置生效
    restart_realm
}

# 查看转发规则
list_forward_rules() {
    log_info "查看转发规则..."
    
    if [ ! -f "$REALM_CONFIG" ]; then
        log_error "配置文件不存在"
        return 1
    fi
    
    rules=$(jq -c '.servers[]' "$REALM_CONFIG")
    
    if [ -z "$rules" ]; then
        log_info "没有找到转发规则"
        return
    fi
    
    echo -e "${BLUE}ID\t名称\t\t监听地址\t\t远程地址${NC}"
    echo -e "${BLUE}--\t----\t\t----------\t\t----------${NC}"
    
    id=1
    echo "$rules" | while IFS= read -r rule; do
        name=$(echo "$rule" | jq -r '.name')
        listen=$(echo "$rule" | jq -r '.listen')
        remote=$(echo "$rule" | jq -r '.remote')
        
        printf "%-6s%-16s%-24s%s\n" "$id" "$name" "$listen" "$remote"
        id=$((id+1))
    done
}

# 删除转发规则
delete_forward_rule() {
    log_info "删除转发规则..."
    
    list_forward_rules
    
    read -p "请输入要删除的规则ID (输入0取消): " id
    
    if [ "$id" -eq 0 ]; then
        log_info "已取消操作"
        return
    fi
    
    rules_count=$(jq '.servers | length' "$REALM_CONFIG")
    
    if [ "$id" -lt 1 ] || [ "$id" -gt "$rules_count" ]; then
        log_error "无效的规则ID"
        return 1
    fi
    
    # 删除规则
    jq --argjson idx "$((id-1))" 'del(.servers[$idx])' "$REALM_CONFIG" > /tmp/config.json
    mv /tmp/config.json "$REALM_CONFIG"
    
    log_info "成功删除规则 #$id"
    
    # 重启服务使配置生效
    restart_realm
}

# 启动Realm
start_realm() {
    log_info "启动Realm服务..."
    
    systemctl start realm
    systemctl enable realm
    
    # 检查服务状态
    if systemctl is-active --quiet realm; then
        log_info "Realm服务已启动"
    else
        log_error "Realm服务启动失败"
        log_info "查看服务状态: systemctl status realm"
        log_info "查看日志: journalctl -u realm -f"
    fi
}

# 停止Realm
stop_realm() {
    log_info "停止Realm服务..."
    
    systemctl stop realm
    
    # 检查服务状态
    if ! systemctl is-active --quiet realm; then
        log_info "Realm服务已停止"
    else
        log_error "Realm服务停止失败"
    fi
}

# 重启Realm
restart_realm() {
    log_info "重启Realm服务..."
    
    systemctl restart realm
    
    # 检查服务状态
    if systemctl is-active --quiet realm; then
        log_info "Realm服务已重启"
    else
        log_error "Realm服务重启失败"
        log_info "查看服务状态: systemctl status realm"
        log_info "查看日志: journalctl -u realm -f"
    fi
}

# 查看日志
view_logs() {
    log_info "查看Realm日志..."
    
    if [ ! -f "/var/log/realm.log" ]; then
        log_error "日志文件不存在"
        return 1
    fi
    
    less +F /var/log/realm.log
}

# 设置定时任务
setup_cronjob() {
    log_info "设置定时任务..."
    
    echo "请选择要设置的定时任务类型:"
    echo "1. 每天凌晨3点重启Realm服务"
    echo "2. 每周日凌晨4点清理Realm日志"
    echo "3. 每月1号凌晨2点自动更新Realm"
    echo "4. 自定义Cron表达式"
    echo "0. 取消"
    
    read -p "请输入选项: " choice
    
    case $choice in
        1)
            cron_expr="0 3 * * *"
            command="systemctl restart realm"
            desc="每天凌晨3点重启Realm服务"
            ;;
        2)
            cron_expr="0 4 * * 0"
            command="find /var/log -name 'realm*.log' -mtime +7 -delete"
            desc="每周日凌晨4点清理7天前的Realm日志"
            ;;
        3)
            cron_expr="0 2 1 * *"
            command="$SCRIPT_PATH update"
            desc="每月1号凌晨2点自动更新Realm"
            ;;
        4)
            read -p "请输入Cron表达式 (例如: 0 3 * * *): " cron_expr
            read -p "请输入要执行的命令: " command
            read -p "请输入任务描述: " desc
            ;;
        0)
            log_info "已取消操作"
            return
            ;;
        *)
            log_error "无效的选项"
            return 1
            ;;
    esac
    
    # 添加到crontab
    (crontab -l 2>/dev/null; echo "$cron_expr $command # Realm: $desc") | crontab -
    
    log_info "已添加定时任务: $desc"
    log_info "Cron表达式: $cron_expr"
}

# 卸载Realm
uninstall_realm() {
    log_warn "即将卸载Realm和相关配置..."
    
    read -p "确定要卸载Realm吗? (y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "已取消卸载操作"
        return
    fi
    
    # 停止服务
    stop_realm
    
    # 禁用服务
    systemctl disable realm
    
    # 删除服务文件
    rm -f /etc/systemd/system/realm.service
    
    # 重载systemd
    systemctl daemon-reload
    
    # 删除二进制文件
    rm -f /usr/local/bin/realm
    
    # 删除配置文件
    read -p "是否删除配置文件? (y/N): " del_config
    if [[ "$del_config" =~ ^[Yy]$ ]]; then
        rm -rf /etc/realm
    fi
    
    # 删除日志文件
    read -p "是否删除日志文件? (y/N): " del_logs
    if [[ "$del_logs" =~ ^[Yy]$ ]]; then
        rm -f /var/log/realm.log
    fi
    
    log_info "Realm已成功卸载"
}

# 卸载脚本
uninstall_script() {
    log_warn "即将卸载此脚本和相关配置..."
    
    read -p "确定要卸载此脚本吗? (y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "已取消卸载操作"
        return
    fi
    
    # 删除脚本文件
    rm -f "$SCRIPT_PATH"
    
    # 删除日志文件
    read -p "是否删除安装日志文件? (y/N): " del_log
    if [[ "$del_log" =~ ^[Yy]$ ]]; then
        rm -f "$LOG_FILE"
    fi
    
    log_info "脚本已成功卸载"
}

# 显示使用信息
show_usage() {
    echo ""
    echo -e "${GREEN}Realm管理脚本 v$SCRIPT_VERSION${NC}"
    echo ""
    echo "用法: $0 [命令]"
    echo ""
    echo "命令:"
    echo "  install            安装Realm"
    echo "  update             更新Realm到最新版本"
    echo "  start              启动Realm服务"
    echo "  stop               停止Realm服务"
    echo "  restart            重启Realm服务"
    echo "  status             查看Realm服务状态"
    echo "  add-rule           添加转发规则"
    echo "  list-rules         列出所有转发规则"
    echo "  delete-rule        删除转发规则"
    echo "  logs               查看Realm日志"
    echo "  cron               设置定时任务"
    echo "  uninstall-realm    卸载Realm"
    echo "  uninstall-script   卸载此脚本"
    echo "  help               显示此帮助信息"
    echo ""
}

# 主函数
main() {
    # 初始化日志文件
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    
    check_system
    install_dependencies
    
    case "$1" in
        install)
            install_realm
            configure_realm
            start_realm
            show_usage
            ;;
        update)
            install_realm
            restart_realm
            ;;
        start)
            start_realm
            ;;
        stop)
            stop_realm
            ;;
        restart)
            restart_realm
            ;;
        status)
            systemctl status realm
            ;;
        add-rule)
            add_forward_rule
            ;;
        list-rules)
            list_forward_rules
            ;;
        delete-rule)
            delete_forward_rule
            ;;
        logs)
            view_logs
            ;;
        cron)
            setup_cronjob
            ;;
        uninstall-realm)
            uninstall_realm
            ;;
        uninstall-script)
            uninstall_script
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            if [ -z "$1" ]; then
                show_usage
            else
                log_error "未知命令: $1"
                show_usage
                exit 1
            fi
            ;;
    esac
}

# 执行主函数
main "$@"    
