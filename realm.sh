#!/bin/bash
# realm.sh - Realm 管理脚本 v2.0 (终极版本检测方案)

# 全局配置
REALM_DIR="/etc/realm"
CONFIG_FILE="$REALM_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
REALM_BIN="$REALM_DIR/realm"
REPO_URL="https://github.com/zhboner/realm"
INSTALLED_VERSION=""
LATEST_VERSION=""
SCRIPT_NAME=$(basename "$0")
SCRIPT_PATH=$(realpath "$0")
VERSION_CACHE_FILE="/tmp/realm_latest_version_cache"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 版本比较函数
compare_versions() {
    local ver1="${1#v}"  # 移除开头的 "v"
    local ver2="${2#v}"
    
    # 分割版本号为数组
    IFS='.' read -ra ver1_parts <<< "$ver1"
    IFS='.' read -ra ver2_parts <<< "$ver2"
    
    # 比较每个部分
    for i in "${!ver1_parts[@]}"; do
        # 如果ver2没有对应的部分，则ver1较新
        if [[ -z ${ver2_parts[i]} ]]; then
            return 1
        fi
        
        # 比较数字部分
        if [[ ${ver1_parts[i]} -gt ${ver2_parts[i]} ]]; then
            return 1
        elif [[ ${ver1_parts[i]} -lt ${ver2_parts[i]} ]]; then
            return 2
        fi
    done
    
    # 如果ver2还有额外的部分，则ver2较新
    if [[ ${#ver2_parts[@]} -gt ${#ver1_parts[@]} ]]; then
        return 2
    fi
    
    return 0
}

# 获取已安装版本（终极可靠方法）
get_installed_version() {
    if [ -f "$REALM_BIN" ]; then
        # 直接运行二进制文件获取版本
        local version_output
        version_output=$("$REALM_BIN" -v 2>&1 || "$REALM_BIN" --version 2>&1)
        
        # 尝试多种模式匹配
        if [[ "$version_output" =~ [vV]?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
            INSTALLED_VERSION="v${BASH_REMATCH[1]}"
        elif [[ "$version_output" =~ [rR]ealm\ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
            INSTALLED_VERSION="v${BASH_REMATCH[1]}"
        else
            # 如果无法解析，使用文件哈希作为唯一标识
            local file_hash
            file_hash=$(sha256sum "$REALM_BIN" | cut -d' ' -f1 | head -c 8)
            INSTALLED_VERSION="自定义版本 (${file_hash})"
        fi
    else
        INSTALLED_VERSION="未安装"
    fi
}

# 获取最新版本（终极可靠方法）
get_latest_version() {
    # 方法1: 检查缓存（24小时内有效）
    if [ -f "$VERSION_CACHE_FILE" ]; then
        local cache_time
        local current_time
        cache_time=$(stat -c %Y "$VERSION_CACHE_FILE")
        current_time=$(date +%s)
        
        if [ $((current_time - cache_time)) -lt 86400 ]; then
            LATEST_VERSION=$(cat "$VERSION_CACHE_FILE")
            echo -e "${CYAN}使用缓存版本: ${GREEN}$LATEST_VERSION${NC}"
            return
        fi
    fi

    # 方法2: 直接解析下载页面
    echo -e "${YELLOW}正在获取最新版本信息...${NC}"
    local download_page
    download_page=$(curl -sL "https://github.com/zhboner/realm/releases")
    
    # 使用精确匹配查找下载链接
    LATEST_VERSION=$(echo "$download_page" | grep -oP 'href="/zhboner/realm/releases/download/v\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    
    # 方法3: 如果下载页面失败，尝试API
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${YELLOW}方法1失败，尝试GitHub API...${NC}"
        LATEST_VERSION=$(curl -s "https://api.github.com/repos/zhboner/realm/releases/latest" | grep '"tag_name":' | cut -d'"' -f4 | sed 's/v//')
    fi
    
    # 方法4: 如果仍然失败，使用硬编码版本
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${YELLOW}无法获取最新版本，使用默认版本${NC}"
        LATEST_VERSION="2.7.0"
    fi
    
    # 添加v前缀并保存到缓存
    LATEST_VERSION="v${LATEST_VERSION}"
    echo "$LATEST_VERSION" > "$VERSION_CACHE_FILE"
    echo -e "${GREEN}检测到最新版本: ${CYAN}$LATEST_VERSION${NC}"
}

# 验证版本一致性
verify_version_consistency() {
    local expected_version="$1"
    
    # 获取实际安装版本
    get_installed_version
    
    # 验证版本是否匹配
    if [[ "$INSTALLED_VERSION" != "未安装" && "$INSTALLED_VERSION" != "$expected_version" ]]; then
        echo -e "${RED}严重警告: 安装版本($INSTALLED_VERSION)与预期版本($expected_version)不匹配!${NC}"
        echo -e "${YELLOW}可能原因:"
        echo "1. 下载文件损坏或不完整"
        echo "2. GitHub Release标签未更新"
        echo "3. 网络劫持或缓存问题"
        echo -e "${NC}"
        
        # 提供解决方案
        echo -e "${CYAN}解决方案:"
        echo "1. 尝试手动下载: wget https://github.com/zhboner/realm/releases/download/$expected_version/realm-x86_64-unknown-linux-gnu.tar.gz"
        echo "2. 检查GitHub Release页面确认最新版本: https://github.com/zhboner/realm/releases"
        echo "3. 等待24小时缓存过期后重试"
        echo -e "${NC}"
        
        return 1
    fi
    
    return 0
}

# 初始化检查
initialize() {
    # 1. 检查root权限
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误：此脚本必须以root权限运行！${NC}"
        exit 1
    fi
    
    # 2. 创建必要目录
    mkdir -p "$REALM_DIR"
    
    # 3. 检查并安装必要依赖
    local missing_deps=()
    for dep in wget tar curl; do
        if ! command -v $dep &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${YELLOW}正在安装必要依赖: ${missing_deps[*]}...${NC}"
        apt update > /dev/null 2>&1
        apt install -y "${missing_deps[@]}" > /dev/null 2>&1
    fi
    
    # 4. 获取版本信息
    get_installed_version
    get_latest_version
}

# 安装/更新Realm
install_realm() {
    initialize
    
    echo -e "${CYAN}当前安装版本: ${YELLOW}$INSTALLED_VERSION${NC}"
    echo -e "${CYAN}最新可用版本: ${GREEN}$LATEST_VERSION${NC}"
    
    # 检查是否已安装最新版
    if [[ "$INSTALLED_VERSION" != "未安装" ]]; then
        compare_versions "${INSTALLED_VERSION#v}" "${LATEST_VERSION#v}"
        local cmp_result=$?
        
        if [ $cmp_result -eq 0 ]; then
            echo -e "${GREEN}已是最新版本，无需更新${NC}"
            return
        elif [ $cmp_result -eq 1 ]; then
            echo -e "${YELLOW}警告：已安装版本 ($INSTALLED_VERSION) 比最新版 ($LATEST_VERSION) 更高${NC}"
            read -p "是否继续降级安装？(y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                return
            fi
        fi
    fi
    
    # 下载并安装
    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/$LATEST_VERSION/realm-x86_64-unknown-linux-gnu.tar.gz"
    
    echo -e "${YELLOW}下载Realm ($LATEST_VERSION)...${NC}"
    wget -O "$REALM_DIR/realm-$LATEST_VERSION.tar.gz" "$DOWNLOAD_URL" > /dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败，请检查网络连接和版本号！${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}解压安装文件...${NC}"
    tar -zxvf "$REALM_DIR/realm-$LATEST_VERSION.tar.gz" -C "$REALM_DIR" > /dev/null
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
    
    # 验证版本一致性
    if ! verify_version_consistency "$LATEST_VERSION"; then
        echo -e "${RED}安装可能不成功，请检查上述警告！${NC}"
    else
        echo -e "${GREEN}Realm ${CYAN}$INSTALLED_VERSION${GREEN} 安装/更新成功！${NC}"
    fi
    
    # 启动服务
    systemctl start realm > /dev/null 2>&1
    systemctl enable realm > /dev/null 2>&1
    echo -e "${BLUE}服务已启动并设置为开机自启${NC}"
}

# 添加转发规则
add_rule() {
    initialize
    
    if [[ "$INSTALLED_VERSION" == "未安装" ]]; then
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
    
    if [[ "$INSTALLED_VERSION" == "未安装" ]]; then
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
    
    if [[ "$INSTALLED_VERSION" == "未安装" ]]; then
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
    
    if [[ "$INSTALLED_VERSION" == "未安装" ]]; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    systemctl start realm
    echo -e "${GREEN}服务已启动！${NC}"
}

stop_service() {
    initialize
    
    if [[ "$INSTALLED_VERSION" == "未安装" ]]; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    systemctl stop realm
    echo -e "${YELLOW}服务已停止！${NC}"
}

restart_service() {
    initialize
    
    if [[ "$INSTALLED_VERSION" == "未安装" ]]; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    systemctl restart realm
    echo -e "${BLUE}服务已重启！${NC}"
}

# 查看日志
view_logs() {
    initialize
    
    if [[ "$INSTALLED_VERSION" == "未安装" ]]; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    journalctl -u realm -f
}

# 清除版本缓存
clear_version_cache() {
    rm -f "$VERSION_CACHE_FILE"
    echo -e "${GREEN}版本缓存已清除！${NC}"
}

# 手动设置版本
manual_set_version() {
    read -p "请输入要使用的版本号 (例如: v2.7.0): " custom_version
    if [[ "$custom_version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        LATEST_VERSION="${custom_version#v}"
        LATEST_VERSION="v${LATEST_VERSION}"
        echo "$LATEST_VERSION" > "$VERSION_CACHE_FILE"
        echo -e "${GREEN}已手动设置版本为: ${CYAN}$LATEST_VERSION${NC}"
    else
        echo -e "${RED}无效的版本格式！${NC}"
    fi
}

# 定时任务管理
cron_management() {
    initialize
    echo -e "\n${BLUE}定时任务管理${NC}"
    echo "1. 添加自动更新任务（每天自动检查更新）"
    echo "2. 移除自动更新任务"
    echo "3. 查看当前定时任务"
    echo "4. 清除版本缓存"
    echo "5. 手动设置版本"
    echo "6. 返回主菜单"
    
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
        4)
            clear_version_cache
            ;;
        5)
            manual_set_version
            ;;
        6) 
            return 
            ;;
        *) 
            echo -e "${RED}无效选项！${NC}" 
            ;;
    esac
}

# 卸载Realm
uninstall_realm() {
    initialize
    
    if [[ "$INSTALLED_VERSION" == "未安装" ]]; then
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
    
    # 清除版本缓存
    clear_version_cache
    
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
    if [[ "$INSTALLED_VERSION" != "未安装" ]]; then
        echo -e "${GREEN}Realm 状态: ${CYAN}已安装 ($INSTALLED_VERSION)${NC}"
        
        # 获取服务状态
        local service_status
        service_status=$(systemctl is-active realm 2>/dev/null)
        
        if [ "$service_status" = "active" ]; then
            # 获取实际运行版本
            local running_version
            running_version=$(timeout 1s "$REALM_BIN" -v 2>/dev/null | awk '{print $NF}')
            
            if [ -n "$running_version" ]; then
                echo -e "${GREEN}服务状态: ${CYAN}运行中 ($running_version)${NC}"
            else
                echo -e "${GREEN}服务状态: ${CYAN}运行中 (版本未知)${NC}"
            fi
        else
            echo -e "${YELLOW}服务状态: ${RED}未运行${NC}"
        fi
    else
        echo -e "${YELLOW}Realm 状态: ${RED}未安装${NC}"
    fi
    
    # 显示最新版本信息
    if [ -n "$LATEST_VERSION" ]; then
        echo -e "${CYAN}最新版本: ${GREEN}$LATEST_VERSION${NC}"
    fi
    
    # 显示缓存状态
    if [ -f "$VERSION_CACHE_FILE" ]; then
        local cache_time
        cache_time=$(date -r "$VERSION_CACHE_FILE" "+%Y-%m-%d %H:%M:%S")
        echo -e "${CYAN}版本缓存: ${YELLOW}有 (更新于 $cache_time)${NC}"
    else
        echo -e "${CYAN}版本缓存: ${YELLOW}无${NC}"
    fi
}

# 显示菜单
show_menu() {
    clear
    echo -e "\n${GREEN}Realm 管理脚本 v2.0${NC}"
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
    "--clear-cache")
        clear_version_cache
        echo -e "${GREEN}版本缓存已清除${NC}"
        exit 0
        ;;
    *)
        # 初始加载版本信息
        get_installed_version
        get_latest_version
        main
        ;;
esac
