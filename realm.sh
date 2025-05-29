#!/bin/bash
# Realm 管理脚本 (美化增强版+版本管理)

# 全局配置
REALM_DIR="/etc/realm"
CONFIG_FILE="$REALM_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
REALM_BIN="$REALM_DIR/realm"
REPO_URL="https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"
SCRIPT_NAME=$(basename "$0")
SCRIPT_PATH=$(realpath "$0")
VERSION_FILE="$REALM_DIR/version.txt"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
MAGENTA='\033[1;35m'
NC='\033[0m'

# 分隔线函数
print_separator() {
    echo -e "${PURPLE}------------------------------------------------${NC}"
}

# 打印标题
print_header() {
    clear
    echo -e "${CYAN}"
    echo "   ____  _____ __  __    _    _   _ "
    echo "  |  _ \\| ____|  \\/  |  / \\  | \\ | |"
    echo "  | |_) |  _| | |\\/| | / _ \\ |  \\| |"
    echo "  |  _ <| |___| |  | |/ ___ \\| |\\  |"
    echo "  |_| \\_\\_____|_|  |_/_/   \\_\\_| \\_|"
    echo -e "${NC}"
    print_separator
}

# 获取已安装版本
get_installed_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        echo "未知"
    fi
}

# 获取最新版本
get_latest_version() {
    # 尝试从GitHub获取最新版本
    local version=$(curl -sI "$REPO_URL" | grep -i 'location:' | grep -oP 'tag/v?\K[\d.]+')
    
    if [ -z "$version" ]; then
        # 如果无法获取，使用默认值
        echo "2.7.0"
    else
        echo "$version"
    fi
}

# 版本比较函数
# 返回值: 0=相等, 1=第一个版本新, 2=第二个版本新
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

# 检查安装状态
check_installation() {
    if [ -f "$REALM_BIN" ]; then
        return 0
    else
        return 1
    fi
}

# 安装/更新Realm
install_realm() {
    # 检查root权限
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误：此脚本必须以root权限运行！${NC}"
        exit 1
    fi
    
    print_header
    echo -e "${YELLOW}正在处理Realm...${NC}"
    print_separator
    
    # 获取版本信息
    local installed_ver=$(get_installed_version)
    local latest_ver=$(get_latest_version)
    
    # 检查是否已安装
    if check_installation; then
        echo -e "${CYAN}当前安装版本: ${YELLOW}$installed_ver${NC}"
        echo -e "${CYAN}最新可用版本: ${GREEN}$latest_ver${NC}"
        print_separator
        
        # 比较版本
        compare_versions "$installed_ver" "$latest_ver"
        local cmp_result=$?
        
        if [ $cmp_result -eq 0 ]; then
            echo -e "${GREEN}已是最新版本，无需更新${NC}"
            return
        elif [ $cmp_result -eq 1 ]; then
            echo -e "${YELLOW}警告：已安装版本 ($installed_ver) 比最新版 ($latest_ver) 更高${NC}"
            read -p "是否继续降级安装？(y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                return
            fi
        else
            echo -e "${YELLOW}发现新版本，准备更新...${NC}"
        fi
    else
        echo -e "${CYAN}最新可用版本: ${GREEN}$latest_ver${NC}"
        echo -e "${YELLOW}开始安装Realm...${NC}"
    fi
    
    # 创建必要目录
    mkdir -p "$REALM_DIR"
    
    # 下载Realm
    echo -e "${CYAN}下载Realm $latest_ver...${NC}"
    wget -P "$REALM_DIR" "$REPO_URL" > /dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败，请检查网络连接！${NC}"
        exit 1
    fi
    
    # 解压文件
    echo -e "${CYAN}解压安装文件...${NC}"
    tar -zxvf "$REALM_DIR"/realm-x86_64-unknown-linux-gnu.tar.gz -C "$REALM_DIR" > /dev/null
    chmod +x "$REALM_BIN"
    rm -f "$REALM_DIR"/*.tar.gz
    
    # 保存版本信息
    echo "$latest_ver" > "$VERSION_FILE"
    
    # 创建默认配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << EOF
[network]
use_udp = true
no_tcp = false

# 转发规则示例
# [[endpoints]]
# listen = "0.0.0.0:23456"
# remote = "target.com:23456"
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
    fi
    
    # 重载系统服务
    systemctl daemon-reload
    
    # 启动服务
    systemctl start realm > /dev/null 2>&1
    systemctl enable realm > /dev/null 2>&1
    
    echo -e "${GREEN}Realm $latest_ver 安装/更新成功！${NC}"
    print_separator
    echo -e "${BLUE}服务已启动并设置为开机自启${NC}"
}

# 添加转发规则
add_rule() {
    if ! check_installation; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    print_header
    echo -e "${BLUE}添加新的转发规则${NC}"
    print_separator
    
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
    if ! check_installation; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    print_header
    echo -e "${BLUE}当前转发规则：${NC}"
    print_separator
    
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
    if ! check_installation; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    view_rules
    
    if [ -z "$(grep '\[endpoints\]' "$CONFIG_FILE")" ]; then
        return
    fi
    
    echo -e "\n${BLUE}删除转发规则${NC}"
    print_separator
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
    if ! check_installation; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    systemctl start realm
    echo -e "${GREEN}服务已启动！${NC}"
}

stop_service() {
    if ! check_installation; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    systemctl stop realm
    echo -e "${YELLOW}服务已停止！${NC}"
}

restart_service() {
    if ! check_installation; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    systemctl restart realm
    echo -e "${BLUE}服务已重启！${NC}"
}

# 查看日志
view_logs() {
    if ! check_installation; then
        echo -e "${RED}错误：Realm未安装！${NC}"
        return
    fi
    
    print_header
    echo -e "${BLUE}Realm 服务日志 (Ctrl+C 退出)${NC}"
    print_separator
    journalctl -u realm -f
}

# 卸载Realm
uninstall_realm() {
    if ! check_installation; then
        echo -e "${YELLOW}Realm 未安装，无需卸载${NC}"
        return
    fi
    
    print_header
    echo -e "${RED}正在卸载Realm...${NC}"
    print_separator
    
    systemctl stop realm
    systemctl disable realm
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$REALM_DIR"
    
    echo -e "${GREEN}Realm 已完全卸载！${NC}"
}

# 显示状态信息
show_status() {
    print_separator
    echo -e "${CYAN}系统信息: ${NC}$(lsb_release -ds)"
    echo -e "${CYAN}内核版本: ${NC}$(uname -r)"
    
    if check_installation; then
        local installed_ver=$(get_installed_version)
        local latest_ver=$(get_latest_version)
        
        echo -e "${GREEN}Realm 状态: ${CYAN}已安装${NC}"
        
        # 版本比较
        compare_versions "$installed_ver" "$latest_ver"
        local cmp_result=$?
        
        if [ $cmp_result -eq 2 ]; then
            echo -e "${YELLOW}有新版本可用: ${GREEN}$latest_ver${NC}"
        fi
        
        # 检查服务状态
        if systemctl is-active --quiet realm; then
            echo -e "${GREEN}服务状态: ${CYAN}运行中${NC}"
        else
            echo -e "${YELLOW}服务状态: ${RED}未运行${NC}"
        fi
    else
        echo -e "${YELLOW}Realm 状态: ${RED}未安装${NC}"
    fi
    print_separator
}

# 显示菜单
show_menu() {
    print_header
    show_status
    
    # 菜单选项
    echo -e "${MAGENTA} 1. 安装/更新 Realm${NC}"
    print_separator
    echo -e "${MAGENTA} 2. 添加转发规则${NC}"
    print_separator
    echo -e "${MAGENTA} 3. 查看转发规则${NC}"
    print_separator
    echo -e "${MAGENTA} 4. 删除转发规则${NC}"
    print_separator
    echo -e "${MAGENTA} 5. 启动服务${NC}"
    print_separator
    echo -e "${MAGENTA} 6. 停止服务${NC}"
    print_separator
    echo -e "${MAGENTA} 7. 重启服务${NC}"
    print_separator
    echo -e "${MAGENTA} 8. 查看日志${NC}"
    print_separator
    echo -e "${MAGENTA} 9. 卸载 Realm${NC}"
    print_separator
    echo -e "${RED} 0. 退出脚本${NC}"
    print_separator
}

# 主函数
main() {
    while true; do
        show_menu
        echo -e "${YELLOW}"
        read -p "请选择操作 (0-9): " choice
        echo -e "${NC}"
        
        case $choice in
            1) install_realm ;;
            2) add_rule ;;
            3) view_rules ;;
            4) delete_rule ;;
            5) start_service ;;
            6) stop_service ;;
            7) restart_service ;;
            8) view_logs ;;
            9) uninstall_realm ;;
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
main
