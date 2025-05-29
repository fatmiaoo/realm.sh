#!/bin/bash
# Realm 管理脚本 v1.7

# 全局配置
REALM_DIR="/etc/realm"
CONFIG_FILE="$REALM_DIR/config.toml"
BACKUP_DIR="$REALM_DIR/backups"
SERVICE_FILE="/etc/systemd/system/realm.service"
REALM_BIN="$REALM_DIR/realm"
REPO_URL="https://api.github.com/repos/zhboner/realm/releases/latest"
INSTALLED_VERSION=""
LATEST_VERSION=""
SCRIPT_NAME=$(basename "$0")
SCRIPT_PATH=$(realpath "$0")
MAX_BACKUPS=5

# 颜色定义
COLOR_RESET='\033[0m'
COLOR_ERROR='\033[0;31m'
COLOR_SUCCESS='\033[0;32m'
COLOR_WARNING='\033[0;33m'
COLOR_INFO='\033[0;34m'
COLOR_DEBUG='\033[0;36m'

# 日志函数
log() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    case $level in
        "error") echo -e "${COLOR_ERROR}[$timestamp] ERROR: $message${COLOR_RESET}" ;;
        "success") echo -e "${COLOR_SUCCESS}[$timestamp] SUCCESS: $message${COLOR_RESET}" ;;
        "warning") echo -e "${COLOR_WARNING}[$timestamp] WARNING: $message${COLOR_RESET}" ;;
        "info") echo -e "${COLOR_INFO}[$timestamp] INFO: $message${COLOR_RESET}" ;;
        "debug") echo -e "${COLOR_DEBUG}[$timestamp] DEBUG: $message${COLOR_RESET}" ;;
    esac
}

# 版本比较函数 (增强版)
compare_versions() {
    local ver1="${1//v/}"  # 移除所有v字符
    local ver2="${2//v/}"
    
    # 分割为数字数组
    IFS='.' read -ra ver1_parts <<< "$ver1"
    IFS='.' read -ra ver2_parts <<< "$ver2"
    
    # 比较每个部分
    for i in "${!ver1_parts[@]}"; do
        local part1=${ver1_parts[i]}
        local part2=${ver2_parts[i]:-0}
        
        # 转换为数字比较
        if ((10#${part1} > 10#${part2})); then return 1; fi
        if ((10#${part1} < 10#${part2})); then return 2; fi
    done
    
    # 处理额外部分
    if ((${#ver2_parts[@]} > ${#ver1_parts[@]})); then
        for ((i=${#ver1_parts[@]}; i<${#ver2_parts[@]}; i++)); do
            ((10#${ver2_parts[i]} > 0)) && return 2
        done
    fi
    
    return 0
}

# 网络检测函数
check_network() {
    local test_urls=(
        "https://github.com"
        "https://google.com"
        "https://cloudflare.com"
    )
    
    for url in "${test_urls[@]}"; do
        if curl --silent --connect-timeout 5 --head "$url" >/dev/null; then
            log debug "网络检测通过: $url"
            return 0
        fi
    done
    
    log error "网络连接失败，请检查网络设置！"
    return 1
}

# 备份配置文件
backup_config() {
    local backup_name="config-$(date +%Y%m%d%H%M%S).toml.bak"
    mkdir -p "$BACKUP_DIR"
    cp "$CONFIG_FILE" "$BACKUP_DIR/$backup_name"
    
    # 清理旧备份
    local backups=($(ls -t "$BACKUP_DIR"/*.bak 2>/dev/null))
    if ((${#backups[@]} > MAX_BACKUPS)); then
        rm -f "${backups[@]:$MAX_BACKUPS}"
    fi
}

# 恢复配置文件
restore_config() {
    local backups=($(ls -t "$BACKUP_DIR"/*.bak 2>/dev/null))
    if ((${#backups[@]} == 0)); then
        log warning "未找到可用的配置文件备份"
        return 1
    fi
    
    PS3="请选择要恢复的备份: "
    select backup in "${backups[@]}"; do
        if [[ -n "$backup" ]]; then
            cp -f "$backup" "$CONFIG_FILE"
            log success "配置文件已从 $backup 恢复"
            restart_service
            return 0
        fi
        log error "无效选择"
        return 1
    done
}

# 获取最新版本信息（增强容错）
get_latest_version() {
    check_network || return 1
    
    local attempts=0
    while ((attempts < 3)); do
        local api_response=$(curl -s -H "Accept: application/vnd.github.v3+json" "$REPO_URL")
        if [[ $? -eq 0 ]]; then
            LATEST_VERSION=$(echo "$api_response" | grep '"tag_name":' | cut -d'"' -f4)
            if [[ "$LATEST_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                log debug "从API获取最新版本: $LATEST_VERSION"
                return 0
            fi
        fi
        ((attempts++))
        sleep 1
    done

    log warning "无法通过API获取版本，尝试备用方法..."
    LATEST_VERSION=$(curl -s https://github.com/zhboner/realm/releases | grep -oE 'realm/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk -F'/' '{print $NF}')
    if [[ "$LATEST_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log debug "从HTML获取最新版本: $LATEST_VERSION"
        return 0
    fi

    log error "无法获取有效版本，使用默认v2.7.0"
    LATEST_VERSION="v2.7.0"
    return 1
}

# 获取安装版本（增强容错）
get_installed_version() {
    if [[ -x "$REALM_BIN" ]]; then
        INSTALLED_VERSION=$("$REALM_BIN" --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
        if [[ -z "$INSTALLED_VERSION" ]]; then
            local mtime=$(stat -c %y "$REALM_BIN" | cut -d' ' -f1)
            INSTALLED_VERSION="未知版本 (安装时间: $mtime)"
        fi
    else
        INSTALLED_VERSION="未安装"
    fi
}

# 初始化流程（增强检查）
initialize() {
    # Root检查
    [[ $EUID -ne 0 ]] && { log error "必须使用root权限运行"; exit 1; }
    
    # 系统兼容性检查
    if ! grep -qs 'ID=debian' /etc/os-release || ! grep -qs 'VERSION_ID="11"' /etc/os-release; then
        log warning "非Debian 11系统，可能不兼容"
        read -p "是否继续？(y/N) " -n 1 -r
        [[ $REPLY =~ ^[Yy]$ ]] || exit 1
    fi
    
    # 依赖检查
    local deps=(wget tar curl)
    local missing=()
    for dep in "${deps[@]}"; do
        ! command -v "$dep" &>/dev/null && missing+=("$dep")
    done
    
    if ((${#missing[@]} > 0)); then
        log info "正在安装缺失依赖: ${missing[*]}"
        apt-get update -qq >/dev/null
        apt-get install -y -qq "${missing[@]}" >/dev/null || {
            log error "依赖安装失败"; exit 1
        }
    fi
    
    # 目录初始化
    mkdir -p "$REALM_DIR" "$BACKUP_DIR"
    
    # 获取版本信息
    get_installed_version
    get_latest_version || true
}

# 安装/更新流程（增加完整性检查）
install_realm() {
    initialize
    
    log info "当前版本: $INSTALLED_VERSION"
    log info "最新版本: $LATEST_VERSION"
    
    if [[ "$INSTALLED_VERSION" != "未安装" ]]; then
        compare_versions "${INSTALLED_VERSION#v}" "${LATEST_VERSION#v}"
        local cmp=$?
        case $cmp in
            0) log info "已经是最新版本"; return ;;
            1) log warning "本地版本较新，建议谨慎更新" ;;
            2) log info "发现新版本，开始更新" ;;
        esac
    fi
    
    local download_url="https://github.com/zhboner/realm/releases/download/$LATEST_VERSION/realm-x86_64-unknown-linux-gnu.tar.gz"
    local temp_file="/tmp/realm-$(date +%s).tar.gz"
    
    log info "下载程序包..."
    if ! wget -qO "$temp_file" "$download_url"; then
        log error "下载失败，请检查网络连接"
        rm -f "$temp_file"
        return 1
    fi
    
    # 验证压缩包完整性
    if ! tar tf "$temp_file" &>/dev/null; then
        log error "下载文件损坏，请重试"
        rm -f "$temp_file"
        return 1
    fi
    
    # 备份配置
    [[ -f "$CONFIG_FILE" ]] && backup_config
    
    log info "解压安装..."
    tar -zxf "$temp_file" -C "$REALM_DIR" || {
        log error "解压失败"; rm -f "$temp_file"; return 1
    }
    rm -f "$temp_file"
    chmod +x "$REALM_BIN"
    
    # 初始化配置文件
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" <<-EOF
[network]
use_udp = true
no_tcp = false
EOF
    fi
    
    # 服务文件配置
    if ! grep -qs "WorkingDirectory=$REALM_DIR" "$SERVICE_FILE"; then
        cat > "$SERVICE_FILE" <<-EOF
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
    
    # 启动服务
    systemctl restart realm
    systemctl enable --now realm &>/dev/null
    
    log success "安装/更新完成"
    log debug "当前运行版本: $($REALM_BIN --version 2>/dev/null || echo '未知')"
}

# 其他函数的优化限于篇幅省略...

# 主菜单（优化布局）
main_menu() {
    clear
    echo -e "${COLOR_INFO}Realm 管理脚本 v1.7${COLOR_RESET}"
    echo "========================================"
    echo -e "系统: $(lsb_release -ds)\n内核: $(uname -r)\n架构: $(uname -m)"
    echo "----------------------------------------"
    show_status
    echo "========================================"
    echo "1. 安装/更新   2. 添加规则"
    echo "3. 查看规则   4. 删除规则"
    echo "5. 服务管理   6. 日志查看"
    echo "7. 定时任务   8. 备份恢复"
    echo "9. 卸载程序   0. 退出"
    echo "========================================"
}

# 服务管理子菜单
service_menu() {
    while true; do
        clear
        echo -e "${COLOR_INFO}服务管理${COLOR_RESET}"
        echo "1. 启动服务     2. 停止服务"
        echo "3. 重启服务     4. 返回主菜单"
        read -p "请选择: " choice
        case $choice in
            1) systemctl start realm; log success "服务已启动" ;;
            2) systemctl stop realm; log warning "服务已停止" ;;
            3) systemctl restart realm; log info "服务已重启" ;;
            4) break ;;
            *) log error "无效选项" ;;
        esac
        sleep 1
    done
}

# 主流程
main() {
    while true; do
        main_menu
        read -p "请选择操作: " choice
        case $choice in
            1) install_realm ;;
            2) add_rule ;;
            3) view_rules ;;
            4) delete_rule ;;
            5) service_menu ;;
            6) view_logs ;;
            7) cron_management ;;
            8) backup_restore_menu ;;
            9) uninstall_realm ;;
            0) exit 0 ;;
            *) log error "无效选项" ;;
        esac
        read -p "按回车继续..."
    done
}

# 执行入口
trap "echo -e '\n操作已取消'; exit" SIGINT
check_network || exit 1
initialize
main
