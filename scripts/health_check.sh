#!/bin/sh
# health_check.sh - Virtual Machine Health Check Script
# 完全兼容版本，适用于所有Linux/Unix系统

set -eu

# ==================== 全局配置 ====================
SCRIPT_NAME="vm-health-check"
VERSION="2.0.0"

# 默认阈值配置（会被配置文件覆盖）
CPU_WARNING=85
CPU_CRITICAL=95
MEMORY_WARNING=90
MEMORY_CRITICAL=95
DISK_WARNING=80
DISK_CRITICAL=90

# 颜色定义（简化为基本支持）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 符号
CHECKMARK="✓"
WARNING="⚠"
CRITICAL="✗"

# 全局变量
EXPLAIN_MODE=false
JSON_OUTPUT=false
LOG_FILE=""
CONFIG_FILE=""

# ==================== 辅助函数 ====================

print_color() {
    color="$1"
    shift
    printf "${color}%s${NC}\n" "$*"
}

log_message() {
    level="$1"
    message="$2"
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ -n "$LOG_FILE" ]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
    fi
}

# 加载配置文件 - 修复版本（不使用source）
load_config() {
    local config_file="${1:-config/thresholds.conf}"
    
    # 记录要加载的配置文件
    log_message "INFO" "尝试加载配置文件: $config_file"
    
    if [ ! -f "$config_file" ]; then
        log_message "WARNING" "配置文件不存在: $config_file，使用默认阈值"
        return 1
    fi
    
    # 安全地读取配置文件（不使用source）
    while IFS='=' read -r key value; do
        # 跳过注释和空行
        case "$key" in
            \#*|'') continue ;;
        esac
        
        # 去除首尾空格
        key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # 根据key设置对应的变量
        case "$key" in
            CPU_WARNING)
                CPU_WARNING="$value"
                log_message "DEBUG" "设置 CPU_WARNING=$value"
                ;;
            CPU_CRITICAL)
                CPU_CRITICAL="$value"
                log_message "DEBUG" "设置 CPU_CRITICAL=$value"
                ;;
            MEMORY_WARNING)
                MEMORY_WARNING="$value"
                log_message "DEBUG" "设置 MEMORY_WARNING=$value"
                ;;
            MEMORY_CRITICAL)
                MEMORY_CRITICAL="$value"
                log_message "DEBUG" "设置 MEMORY_CRITICAL=$value"
                ;;
            DISK_WARNING)
                DISK_WARNING="$value"
                log_message "DEBUG" "设置 DISK_WARNING=$value"
                ;;
            DISK_CRITICAL)
                DISK_CRITICAL="$value"
                log_message "DEBUG" "设置 DISK_CRITICAL=$value"
                ;;
            *)
                # 忽略未知配置
                log_message "DEBUG" "忽略未知配置项: $key=$value"
                ;;
        esac
    done < "$config_file"
    
    log_message "INFO" "配置加载完成: CPU=$CPU_WARNING/$CPU_CRITICAL, 内存=$MEMORY_WARNING/$MEMORY_CRITICAL, 磁盘=$DISK_WARNING/$DISK_CRITICAL"
    return 0
}

# 创建默认配置文件
create_default_config() {
    local config_file="$1"
    local config_dir=$(dirname "$config_file")
    
    # 创建配置目录
    mkdir -p "$config_dir"
    
    # 创建默认配置文件
    cat > "$config_file" << 'EOF'
# VM健康检查配置文件
# CPU使用率阈值（百分比）
CPU_WARNING=85
CPU_CRITICAL=95

# 内存使用率阈值（百分比）
MEMORY_WARNING=90
MEMORY_CRITICAL=95

# 磁盘使用率阈值（百分比）
DISK_WARNING=80
DISK_CRITICAL=90
EOF
    
    log_message "INFO" "默认配置文件已创建: $config_file"
    echo "默认配置文件已创建: $config_file"
    return 0
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ==================== 健康检查函数 ====================

check_cpu() {
    echo ""
    print_color "$CYAN" "[CPU 检查]"
    
    cpu_usage=""
    cpu_status="OK"
    cpu_message="CPU使用率正常"
    
    # 方法1: 使用/proc/stat (最可靠)
    if [ -f /proc/stat ]; then
        # 读取第一行CPU信息
        read cpu user nice system idle iowait irq softirq steal rest < /proc/stat
        
        # 计算总时间和空闲时间
        total=$((user + nice + system + idle + iowait + irq + softirq + steal))
        used=$((total - idle))
        
        if [ "$total" -gt 0 ]; then
            cpu_usage=$((used * 100 / total))
            echo "当前CPU使用率: ${cpu_usage}%"
        fi
    fi
    
    # 方法2: 使用top命令 (备用)
    if [ -z "$cpu_usage" ] && command_exists "top"; then
        # 简化的top命令解析
        cpu_line=$(top -bn1 | grep -E "^(%Cpu|Cpu)" | head -1)
        if [ -n "$cpu_line" ]; then
            # 尝试不同的解析方式
            if echo "$cpu_line" | grep -q "Cpu(s)"; then
                cpu_usage=$(echo "$cpu_line" | awk '{print $2 + $4}' | cut -d'.' -f1)
            else
                cpu_usage=$(echo "$cpu_line" | awk '{print $2}' | cut -d'.' -f1)
            fi
            echo "当前CPU使用率: ${cpu_usage}%"
        fi
    fi
    
    if [ -z "$cpu_usage" ]; then
        cpu_status="UNKNOWN"
        cpu_message="无法获取CPU信息"
        cpu_usage="N/A"
    else
        echo "警告阈值: ${CPU_WARNING}%"
        echo "严重阈值: ${CPU_CRITICAL}%"
        
        # 数值比较
        if [ "$cpu_usage" -gt "$CPU_CRITICAL" ] 2>/dev/null; then
            cpu_status="CRITICAL"
            cpu_message="CPU使用率严重过高！"
        elif [ "$cpu_usage" -gt "$CPU_WARNING" ] 2>/dev/null; then
            cpu_status="WARNING"
            cpu_message="CPU使用率过高"
        fi
    fi
    
    # 显示状态
    case "$cpu_status" in
        "OK") print_color "$GREEN" "${CHECKMARK} ${cpu_message}" ;;
        "WARNING") print_color "$YELLOW" "${WARNING} ${cpu_message}" ;;
        "CRITICAL") print_color "$RED" "${CRITICAL} ${cpu_message}" ;;
        *) print_color "$BLUE" "? ${cpu_message}" ;;
    esac
    
    # 存储结果
    echo "CPU|${cpu_status}|${cpu_usage}%|${cpu_message}"
}

check_memory() {
    echo ""
    print_color "$CYAN" "[内存 检查]"
    
    mem_usage=""
    mem_status="OK"
    mem_message="内存使用率正常"
    
    # 方法1: 使用free命令
    if command_exists "free"; then
        # 获取内存信息
        mem_total=$(free -m | awk '/Mem:/ {print $2}')
        mem_used=$(free -m | awk '/Mem:/ {print $3}')
        
        if [ "$mem_total" -gt 0 ]; then
            mem_usage=$((mem_used * 100 / mem_total))
            
            echo "内存总量: ${mem_total}MB"
            echo "已使用: ${mem_used}MB"
            echo "使用率: ${mem_usage}%"
            echo "警告阈值: ${MEMORY_WARNING}%"
            echo "严重阈值: ${MEMORY_CRITICAL}%"
        fi
    fi
    
    # 方法2: 使用/proc/meminfo (备用)
    if [ -z "$mem_usage" ] && [ -f /proc/meminfo ]; then
        mem_total=$(grep 'MemTotal:' /proc/meminfo | awk '{print $2}')
        mem_free=$(grep 'MemFree:' /proc/meminfo | awk '{print $2}')
        mem_buffers=$(grep 'Buffers:' /proc/meminfo | awk '{print $2}')
        mem_cached=$(grep '^Cached:' /proc/meminfo | awk '{print $2}')
        
        if [ "$mem_total" -gt 0 ]; then
            # 计算实际使用内存
            mem_used=$((mem_total - mem_free - mem_buffers - mem_cached))
            mem_usage=$((mem_used * 100 / mem_total))
            
            echo "内存总量: $((mem_total / 1024))MB"
            echo "使用率: ${mem_usage}%"
            echo "警告阈值: ${MEMORY_WARNING}%"
            echo "严重阈值: ${MEMORY_CRITICAL}%"
        fi
    fi
    
    if [ -z "$mem_usage" ]; then
        mem_status="UNKNOWN"
        mem_message="无法获取内存信息"
        mem_usage="N/A"
    else
        # 数值比较
        if [ "$mem_usage" -gt "$MEMORY_CRITICAL" ] 2>/dev/null; then
            mem_status="CRITICAL"
            mem_message="内存使用率严重过高！"
        elif [ "$mem_usage" -gt "$MEMORY_WARNING" ] 2>/dev/null; then
            mem_status="WARNING"
            mem_message="内存使用率过高"
        fi
    fi
    
    # 显示状态
    case "$mem_status" in
        "OK") print_color "$GREEN" "${CHECKMARK} ${mem_message}" ;;
        "WARNING") print_color "$YELLOW" "${WARNING} ${mem_message}" ;;
        "CRITICAL") print_color "$RED" "${CRITICAL} ${mem_message}" ;;
        *) print_color "$BLUE" "? ${cpu_message}" ;;
    esac
    
    # 存储结果
    echo "内存|${mem_status}|${mem_usage}%|${mem_message}"
}

check_disk() {
    echo ""
    print_color "$CYAN" "[磁盘 检查]"
    
    disk_status="OK"
    disk_message="磁盘空间正常"
    disk_usage=""
    
    # 使用df命令
    if command_exists "df"; then
        # 获取根分区使用率
        disk_line=$(df / | tail -1)
        if [ -n "$disk_line" ]; then
            disk_usage=$(echo "$disk_line" | awk '{print $5}' | sed 's/%//')
            disk_total=$(echo "$disk_line" | awk '{print $2}')
            disk_used=$(echo "$disk_line" | awk '{print $3}')
            disk_avail=$(echo "$disk_line" | awk '{print $4}')
            
            echo "磁盘总量: ${disk_total}"
            echo "已使用: ${disk_used}"
            echo "可用空间: ${disk_avail}"
            echo "使用率: ${disk_usage}%"
            echo "警告阈值: ${DISK_WARNING}%"
            echo "严重阈值: ${DISK_CRITICAL}%"
        fi
    fi
    
    if [ -z "$disk_usage" ]; then
        disk_status="UNKNOWN"
        disk_message="无法获取磁盘信息"
        disk_usage="N/A"
    else
        # 数值比较
        if [ "$disk_usage" -gt "$DISK_CRITICAL" ] 2>/dev/null; then
            disk_status="CRITICAL"
            disk_message="磁盘空间严重不足！"
        elif [ "$disk_usage" -gt "$DISK_WARNING" ] 2>/dev/null; then
            disk_status="WARNING"
            disk_message="磁盘空间不足"
        fi
        
        # 检查其他分区
        echo ""
        echo "其他分区检查:"
        df -h | grep '^/dev/' | grep -v '/$' | head -3 | while read line; do
            part_usage=$(echo "$line" | awk '{print $5}')
            part_mount=$(echo "$line" | awk '{print $6}')
            echo "  ${part_mount}: ${part_usage}"
        done
    fi
    
    # 显示状态
    case "$disk_status" in
        "OK") print_color "$GREEN" "${CHECKMARK} ${disk_message}" ;;
        "WARNING") print_color "$YELLOW" "${WARNING} ${disk_message}" ;;
        "CRITICAL") print_color "$RED" "${CRITICAL} ${disk_message}" ;;
        *) print_color "$BLUE" "? ${disk_message}" ;;
    esac
    
    # 存储结果
    echo "磁盘|${disk_status}|${disk_usage}%|${disk_message}"
}

# ==================== 输出函数 ====================

generate_report() {
    echo ""
    print_color "$PURPLE" "=== 虚拟机健康检查报告 ==="
    echo "检查时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "主机名称: $(hostname 2>/dev/null || echo 'unknown')"
    echo "操作系统: $(uname -s) $(uname -r)"
    echo "脚本版本: ${VERSION}"
    echo "使用的阈值配置:"
    echo "  CPU: 警告=${CPU_WARNING}%, 严重=${CPU_CRITICAL}%"
    echo "  内存: 警告=${MEMORY_WARNING}%, 严重=${MEMORY_CRITICAL}%"
    echo "  磁盘: 警告=${DISK_WARNING}%, 严重=${DISK_CRITICAL}%"
    echo ""
    
    echo "检查结果:"
    echo "----------------------------------------"
    
    # 存储结果的临时文件
    temp_file=$(mktemp 2>/dev/null || echo "/tmp/health_$$.tmp")
    
    # 执行检查并捕获结果
    {
        check_cpu
        check_memory
        check_disk
    } > "$temp_file"
    
    # 显示结果并计算总体状态
    overall_status=0
    while IFS='|' read -r component status value message; do
        case "$status" in
            "CRITICAL")
                overall_status=2
                status_color="$RED"
                ;;
            "WARNING")
                if [ "$overall_status" -lt 1 ]; then
                    overall_status=1
                fi
                status_color="$YELLOW"
                ;;
            "OK")
                status_color="$GREEN"
                ;;
            *)
                status_color="$BLUE"
                ;;
        esac
        
        printf "%-8s ${status_color}%-10s${NC} %-10s %s\n" \
            "$component" "$status" "$value" "$message"
    done < "$temp_file"
    
    echo ""
    print_color "$PURPLE" "=== 总体状态 ==="
    
    case $overall_status in
        0) print_color "$GREEN" "✅ 系统健康状态良好，所有指标正常。" ;;
        1) print_color "$YELLOW" "⚠️  系统存在警告，建议关注并处理。" ;;
        2) print_color "$RED" "❌ 系统存在严重问题，请立即处理！" ;;
    esac
    
    echo "退出代码: ${overall_status} (0:正常, 1:警告, 2:严重)"
    
    # 清理临时文件
    rm -f "$temp_file"
    
    return $overall_status
}

generate_explanation() {
    echo ""
    print_color "$BLUE" "=== 详细解释模式 ==="
    echo "以下是各项检查指标的详细解释："
    echo ""
    
    echo "${CYAN}CPU检查说明：${NC}"
    echo "  • 检查CPU当前使用率"
    echo "  • 阈值设置: 警告=${CPU_WARNING}%, 严重=${CPU_CRITICAL}%"
    echo "  • CPU使用率过高可能影响系统响应速度和应用性能"
    echo "  • 建议措施: 监控进程、优化代码、增加CPU资源"
    echo ""
    
    echo "${CYAN}内存检查说明：${NC}"
    echo "  • 检查内存使用率和总量"
    echo "  • 阈值设置: 警告=${MEMORY_WARNING}%, 严重=${MEMORY_CRITICAL}%"
    echo "  • 内存不足可能导致应用崩溃或系统变慢"
    echo "  • 建议措施: 检查内存泄漏、优化应用、增加内存"
    echo ""
    
    echo "${CYAN}磁盘检查说明：${NC}"
    echo "  • 检查磁盘空间使用率"
    echo "  • 阈值设置: 警告=${DISK_WARNING}%, 严重=${DISK_CRITICAL}%"
    echo "  • 磁盘空间不足可能导致无法写入数据或系统异常"
    echo "  • 建议措施: 清理日志文件、删除临时文件、扩展磁盘"
    echo ""
    
    echo "${CYAN}阈值调整：${NC}"
    echo "  可在配置文件 config/thresholds.conf 中修改阈值"
    echo "  配置文件格式:"
    echo "    CPU_WARNING=85"
    echo "    CPU_CRITICAL=95"
    echo "    MEMORY_WARNING=90"
    echo "    ..."
}

# ==================== JSON输出函数 ====================

generate_json_output() {
    echo "{"
    echo "  \"script\": \"${SCRIPT_NAME}\","
    echo "  \"version\": \"${VERSION}\","
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"hostname\": \"$(hostname 2>/dev/null || echo 'unknown')\","
    echo "  \"thresholds\": {"
    echo "    \"cpu_warning\": ${CPU_WARNING},"
    echo "    \"cpu_critical\": ${CPU_CRITICAL},"
    echo "    \"memory_warning\": ${MEMORY_WARNING},"
    echo "    \"memory_critical\": ${MEMORY_CRITICAL},"
    echo "    \"disk_warning\": ${DISK_WARNING},"
    echo "    \"disk_critical\": ${DISK_CRITICAL}"
    echo "  },"
    
    # 存储结果的临时文件
    temp_file=$(mktemp 2>/dev/null || echo "/tmp/health_json_$$.tmp")
    
    {
        check_cpu
        check_memory
        check_disk
    } > "$temp_file"
    
    # 计算总体状态
    overall_status=0
    while IFS='|' read -r component status value message; do
        case "$status" in
            "CRITICAL") overall_status=2 ;;
            "WARNING") [ "$overall_status" -lt 1 ] && overall_status=1 ;;
        esac
    done < "$temp_file"
    
    echo "  \"overall_status\": ${overall_status},"
    echo "  \"checks\": ["
    
    # 读取结果并生成JSON
    first=true
    while IFS='|' read -r component status value message; do
        # 转换状态码
        case "$status" in
            "OK") status_code=0 ;;
            "WARNING") status_code=1 ;;
            "CRITICAL") status_code=2 ;;
            *) status_code=3 ;;
        esac
        
        # 提取数值
        numeric_value=$(echo "$value" | sed 's/[^0-9.]//g')
        numeric_value=${numeric_value:-0}
        
        if [ "$first" = true ]; then
            first=false
        else
            echo "    ,"
        fi
        
        echo "    {"
        echo "      \"component\": \"${component}\","
        echo "      \"status\": \"${status}\","
        echo "      \"status_code\": ${status_code},"
        echo "      \"value\": ${numeric_value},"
        echo "      \"message\": \"${message}\""
        echo -n "    }"
    done < "$temp_file"
    
    echo ""
    echo "  ]"
    echo "}"
    
    rm -f "$temp_file"
}

# ==================== 主函数 ====================

main() {
    start_time=$(date +%s)
    
    print_color "$GREEN" "🚀 虚拟机健康检查开始..."
    echo "脚本: ${SCRIPT_NAME} v${VERSION}"
    echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # 记录日志
    log_message "INFO" "健康检查开始"
    
    # 执行检查
    if [ "$JSON_OUTPUT" = true ]; then
        generate_json_output
    else
        generate_report
        exit_code=$?
        
        if [ "$EXPLAIN_MODE" = true ]; then
            generate_explanation
        fi
    fi
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    echo ""
    print_color "$PURPLE" "=== 执行统计 ==="
    echo "检查项目数: 3"
    echo "执行耗时: ${duration}秒"
    
    log_message "INFO" "健康检查完成，耗时${duration}秒"
    
    return ${exit_code:-0}
}

# ==================== 参数处理 ====================

show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help          显示此帮助信息"
    echo "  -v, --version       显示版本信息"
    echo "  -e, --explain       显示详细解释"
    echo "  -j, --json          以JSON格式输出"
    echo "  -l, --log FILE      指定日志文件"
    echo "  -c, --config FILE   指定配置文件路径"
    echo ""
    echo "示例:"
    echo "  $0                   执行完整检查"
    echo "  $0 --explain        执行检查并显示详细解释"
    echo "  $0 --json           以JSON格式输出"
    echo "  $0 --config custom.conf 使用自定义配置文件"
}

show_version() {
    echo "${SCRIPT_NAME} v${VERSION}"
}

# 参数解析
parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            -e|--explain)
                EXPLAIN_MODE=true
                ;;
            -j|--json)
                JSON_OUTPUT=true
                ;;
            -l|--log)
                if [ -n "$2" ]; then
                    LOG_FILE="$2"
                    shift
                else
                    echo "错误: --log 需要日志文件路径"
                    exit 1
                fi
                ;;
            -c|--config)
                if [ -n "$2" ]; then
                    CONFIG_FILE="$2"
                    shift
                else
                    echo "错误: --config 需要配置文件路径"
                    exit 1
                fi
                ;;
            *)
                echo "错误: 未知选项 '$1'"
                show_help
                exit 1
                ;;
        esac
        shift
    done
}

# ==================== 执行入口 ====================

# 执行主函数
if [ $# -eq 0 ]; then
    # 无参数：加载默认配置
    if ! load_config; then
        echo "使用默认阈值配置"
    fi
    main
else
    # 有参数：先解析参数
    parse_arguments "$@"
    # 加载配置（如果有指定配置文件，使用指定的）
    if [ -n "$CONFIG_FILE" ]; then
        if ! load_config "$CONFIG_FILE"; then
            echo "使用默认阈值配置"
        fi
    else
        if ! load_config; then
            echo "使用默认阈值配置"
        fi
    fi
    main
fi