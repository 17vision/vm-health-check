#!/bin/sh
# health_check.sh - Virtual Machine Health Check Script
# 改进倒计时显示，每秒更新

set -eu

# ==================== 全局配置 ====================
SCRIPT_NAME="vm-health-check"
VERSION="1.0.0"

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 日志配置
LOG_BASE_DIR="${PROJECT_ROOT}/logs"
LOG_FILE="${LOG_BASE_DIR}/health-check-$(date +%Y%m%d).log"

# 默认配置文件路径
DEFAULT_CONFIG_FILE="${PROJECT_ROOT}/config/thresholds.conf"

# 默认阈值配置（会被配置文件覆盖）
CPU_WARNING=85
CPU_CRITICAL=95
MEMORY_WARNING=90
MEMORY_CRITICAL=95
DISK_WARNING=80
DISK_CRITICAL=90

# 全局变量
EXPLAIN_MODE=false
JSON_OUTPUT=false
MONITOR_MODE=false
MONITOR_INTERVAL=60  # 默认值，会被配置文件和命令行覆盖
COUNTDOWN_REFRESH=1  # 倒计时刷新频率（秒）
MAX_CHECKS=0
CONFIG_FILE=""
VERBOSE=false

# 检查结果存储
CPU_RESULT=""
MEMORY_RESULT=""
DISK_RESULT=""
CPU_USAGE=""
MEMORY_USAGE=""
DISK_USAGE=""
CPU_STATUS=""
MEMORY_STATUS=""
DISK_STATUS=""

# ==================== 基本辅助函数 ====================

print_color() {
    if [ -t 1 ]; then  # 检查是否是终端输出
        color="$1"
        shift
        case "$color" in
            RED) printf "\033[0;31m%s\033[0m\n" "$*" ;;
            GREEN) printf "\033[0;32m%s\033[0m\n" "$*" ;;
            YELLOW) printf "\033[1;33m%s\033[0m\n" "$*" ;;
            BLUE) printf "\033[0;34m%s\033[0m\n" "$*" ;;
            PURPLE) printf "\033[0;35m%s\033[0m\n" "$*" ;;
            CYAN) printf "\033[0;36m%s\033[0m\n" "$*" ;;
            *) printf "%s\n" "$*" ;;
        esac
    else
        shift
        printf "%s\n" "$*"
    fi
}

log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 确保日志目录存在
    mkdir -p "$LOG_BASE_DIR" 2>/dev/null || return 1
    
    # 写入日志文件
    echo "[${timestamp}] ${message}" >> "$LOG_FILE" 2>/dev/null || return 1
    
    # 同时输出到控制台（如果是verbose模式）
    if [ "$VERBOSE" = true ]; then
        echo "[${timestamp}] ${message}"
    fi
}

# ==================== 配置文件管理 ====================

load_config() {
    local config_file="${1:-$DEFAULT_CONFIG_FILE}"
    
    if [ "$VERBOSE" = true ]; then
        echo "加载配置文件: $config_file"
    fi
    
    if [ ! -f "$config_file" ]; then
        log_message "警告: 配置文件不存在: $config_file，使用默认阈值"
        return 1
    fi
    
    # 安全地读取配置文件
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
                [ "$VERBOSE" = true ] && echo "设置 CPU_WARNING=$value"
                ;;
            CPU_CRITICAL)
                CPU_CRITICAL="$value"
                [ "$VERBOSE" = true ] && echo "设置 CPU_CRITICAL=$value"
                ;;
            MEMORY_WARNING)
                MEMORY_WARNING="$value"
                [ "$VERBOSE" = true ] && echo "设置 MEMORY_WARNING=$value"
                ;;
            MEMORY_CRITICAL)
                MEMORY_CRITICAL="$value"
                [ "$VERBOSE" = true ] && echo "设置 MEMORY_CRITICAL=$value"
                ;;
            DISK_WARNING)
                DISK_WARNING="$value"
                [ "$VERBOSE" = true ] && echo "设置 DISK_WARNING=$value"
                ;;
            DISK_CRITICAL)
                DISK_CRITICAL="$value"
                [ "$VERBOSE" = true ] && echo "设置 DISK_CRITICAL=$value"
                ;;
            CHECK_INTERVAL)
                # 只在没有命令行参数时使用配置文件的间隔
                if [ -z "$MONITOR_INTERVAL_SET" ]; then
                    MONITOR_INTERVAL="$value"
                fi
                [ "$VERBOSE" = true ] && echo "设置 检查间隔=$value秒"
                ;;
            COUNTDOWN_REFRESH)
                COUNTDOWN_REFRESH="$value"
                [ "$VERBOSE" = true ] && echo "设置 倒计时刷新频率=$value秒"
                ;;
            ALERT_COOLDOWN)
                ALERT_COOLDOWN="$value"
                [ "$VERBOSE" = true ] && echo "设置 告警冷却时间=$value秒"
                ;;
            LOG_BASE_DIR)
                case "$value" in
                    /*) LOG_BASE_DIR="$value" ;;
                    *) LOG_BASE_DIR="${PROJECT_ROOT}/$value" ;;
                esac
                LOG_FILE="${LOG_BASE_DIR}/health-check-$(date +%Y%m%d).log"
                [ "$VERBOSE" = true ] && echo "设置 日志目录=$LOG_BASE_DIR"
                ;;
            IMPORTANT_MOUNTS)
                IMPORTANT_MOUNTS="$value"
                [ "$VERBOSE" = true ] && echo "设置 重要分区=$value"
                ;;
            *)
                # 忽略未知配置
                [ "$VERBOSE" = true ] && echo "忽略未知配置项: $key=$value"
                ;;
        esac
    done < "$config_file"
    
    if [ "$VERBOSE" = true ]; then
        echo "配置加载完成"
        echo "CPU阈值: 警告=${CPU_WARNING}%, 严重=${CPU_CRITICAL}%"
        echo "内存阈值: 警告=${MEMORY_WARNING}%, 严重=${MEMORY_CRITICAL}%"
        echo "磁盘阈值: 警告=${DISK_WARNING}%, 严重=${DISK_CRITICAL}%"
        echo ""
    fi
    
    return 0
}

# ==================== 倒计时函数 ====================

# 改进的倒计时函数，每秒更新
countdown() {
    local seconds="$1"
    local refresh_rate="${2:-1}"  # 刷新频率，默认1秒
    
    # 计算需要刷新的次数
    local total_refreshes=$((seconds / refresh_rate))
    
    for i in $(seq $total_refreshes -1 0); do
        local remaining=$((i * refresh_rate))
        
        # 清除上一行并显示倒计时
        printf "\r\033[K等待: %3d 秒 (Ctrl+C 停止) " "$remaining"
        
        # 如果不是最后一次，就等待刷新间隔
        if [ $i -gt 0 ]; then
            sleep "$refresh_rate"
        fi
    done
    
    # 清除倒计时显示
    printf "\r\033[K"
}

# 简单的倒计时（兼容模式）
simple_countdown() {
    local seconds="$1"
    
    for i in $(seq "$seconds" -1 1); do
        printf "\r等待: %3d 秒 (Ctrl+C 停止) " "$i"
        sleep 1
    done
    
    printf "\r\033[K"
}

# ==================== 健康检查函数 ====================

check_cpu() {
    local cpu_usage=""
    local cpu_status="OK"
    local cpu_message="CPU使用率正常"
    
    # 方法1: 使用/proc/stat
    if [ -f /proc/stat ]; then
        read cpu user nice system idle iowait irq softirq steal rest < /proc/stat
        total=$((user + nice + system + idle + iowait + irq + softirq + steal))
        used=$((total - idle))
        
        if [ "$total" -gt 0 ]; then
            cpu_usage=$((used * 100 / total))
        fi
    fi
    
    # 方法2: 使用top命令 (备用)
    if [ -z "$cpu_usage" ] && command -v top >/dev/null 2>&1; then
        cpu_line=$(top -bn1 | grep -E "^(%Cpu|Cpu)" | head -1)
        if [ -n "$cpu_line" ]; then
            if echo "$cpu_line" | grep -q "Cpu(s)"; then
                cpu_usage=$(echo "$cpu_line" | awk '{print $2 + $4}' | cut -d'.' -f1)
            else
                cpu_usage=$(echo "$cpu_line" | awk '{print $2}' | cut -d'.' -f1)
            fi
        fi
    fi
    
    if [ -z "$cpu_usage" ]; then
        cpu_status="UNKNOWN"
        cpu_message="无法获取CPU信息"
        cpu_usage="N/A"
    else
        # 数值比较
        if [ "$cpu_usage" -gt "$CPU_CRITICAL" ] 2>/dev/null; then
            cpu_status="CRITICAL"
            cpu_message="CPU使用率严重过高！"
        elif [ "$cpu_usage" -gt "$CPU_WARNING" ] 2>/dev/null; then
            cpu_status="WARNING"
            cpu_message="CPU使用率过高"
        fi
    fi
    
    # 存储结果
    CPU_USAGE="$cpu_usage"
    CPU_STATUS="$cpu_status"
    CPU_RESULT="$cpu_message"
    
    if [ "$JSON_OUTPUT" != true ] && [ "$MONITOR_MODE" != true ]; then
        echo ""
        print_color "CYAN" "[CPU 检查]"
        if [ "$cpu_usage" != "N/A" ]; then
            echo "当前CPU使用率: ${cpu_usage}%"
            echo "警告阈值: ${CPU_WARNING}%"
            echo "严重阈值: ${CPU_CRITICAL}%"
        fi
        
        case "$cpu_status" in
            "OK") print_color "GREEN" "✓ ${cpu_message}" ;;
            "WARNING") print_color "YELLOW" "⚠ ${cpu_message}" ;;
            "CRITICAL") print_color "RED" "✗ ${cpu_message}" ;;
            *) print_color "BLUE" "? ${cpu_message}" ;;
        esac
    fi
    
    log_message "CPU检查: 使用率=${cpu_usage}%, 状态=${cpu_status}"
    
    return 0
}

check_memory() {
    local mem_usage=""
    local mem_status="OK"
    local mem_message="内存使用率正常"
    
    # 使用free命令
    if command -v free >/dev/null 2>&1; then
        mem_total=$(free -m | awk '/Mem:/ {print $2}')
        mem_used=$(free -m | awk '/Mem:/ {print $3}')
        
        if [ "$mem_total" -gt 0 ]; then
            mem_usage=$((mem_used * 100 / mem_total))
        fi
    fi
    
    # 备用方法: 使用/proc/meminfo
    if [ -z "$mem_usage" ] && [ -f /proc/meminfo ]; then
        mem_total=$(grep 'MemTotal:' /proc/meminfo | awk '{print $2}')
        mem_free=$(grep 'MemFree:' /proc/meminfo | awk '{print $2}')
        mem_buffers=$(grep 'Buffers:' /proc/meminfo | awk '{print $2}')
        mem_cached=$(grep '^Cached:' /proc/meminfo | awk '{print $2}')
        
        if [ "$mem_total" -gt 0 ]; then
            mem_used=$((mem_total - mem_free - mem_buffers - mem_cached))
            mem_usage=$((mem_used * 100 / mem_total))
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
    
    # 存储结果
    MEMORY_USAGE="$mem_usage"
    MEMORY_STATUS="$mem_status"
    MEMORY_RESULT="$mem_message"
    
    if [ "$JSON_OUTPUT" != true ] && [ "$MONITOR_MODE" != true ]; then
        echo ""
        print_color "CYAN" "[内存 检查]"
        if [ "$mem_usage" != "N/A" ]; then
            echo "内存使用率: ${mem_usage}%"
            echo "警告阈值: ${MEMORY_WARNING}%"
            echo "严重阈值: ${MEMORY_CRITICAL}%"
        fi
        
        case "$mem_status" in
            "OK") print_color "GREEN" "✓ ${mem_message}" ;;
            "WARNING") print_color "YELLOW" "⚠ ${mem_message}" ;;
            "CRITICAL") print_color "RED" "✗ ${mem_message}" ;;
            *) print_color "BLUE" "? ${mem_message}" ;;
        esac
    fi
    
    log_message "内存检查: 使用率=${mem_usage}%, 状态=${mem_status}"
    
    return 0
}

check_disk() {
    local disk_usage=""
    local disk_status="OK"
    local disk_message="磁盘空间正常"
    
    # 使用df命令
    if command -v df >/dev/null 2>&1; then
        # 获取根分区使用率
        disk_line=$(df / 2>/dev/null | tail -1)
        if [ -n "$disk_line" ]; then
            disk_usage=$(echo "$disk_line" | awk '{print $5}' | sed 's/%//')
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
    fi
    
    # 存储结果
    DISK_USAGE="$disk_usage"
    DISK_STATUS="$disk_status"
    DISK_RESULT="$disk_message"
    
    if [ "$JSON_OUTPUT" != true ] && [ "$MONITOR_MODE" != true ]; then
        echo ""
        print_color "CYAN" "[磁盘 检查]"
        if [ "$disk_usage" != "N/A" ]; then
            echo "根分区使用率: ${disk_usage}%"
            echo "警告阈值: ${DISK_WARNING}%"
            echo "严重阈值: ${DISK_CRITICAL}%"
        fi
        
        case "$disk_status" in
            "OK") print_color "GREEN" "✓ ${disk_message}" ;;
            "WARNING") print_color "YELLOW" "⚠ ${disk_message}" ;;
            "CRITICAL") print_color "RED" "✗ ${disk_message}" ;;
            *) print_color "BLUE" "? ${disk_message}" ;;
        esac
    fi
    
    log_message "磁盘检查: 使用率=${disk_usage}%, 状态=${disk_status}"
    
    return 0
}

# ==================== JSON输出函数 ====================

generate_json_output() {
    # 执行检查
    check_cpu >/dev/null 2>&1
    check_memory >/dev/null 2>&1
    check_disk >/dev/null 2>&1
    
    # 计算总体状态
    local overall_status=0
    case "$CPU_STATUS" in
        "CRITICAL") overall_status=2 ;;
        "WARNING") [ $overall_status -lt 1 ] && overall_status=1 ;;
    esac
    case "$MEMORY_STATUS" in
        "CRITICAL") overall_status=2 ;;
        "WARNING") [ $overall_status -lt 1 ] && overall_status=1 ;;
    esac
    case "$DISK_STATUS" in
        "CRITICAL") overall_status=2 ;;
        "WARNING") [ $overall_status -lt 1 ] && overall_status=1 ;;
    esac
    
    # 生成JSON
    cat << EOF
{
  "script": "${SCRIPT_NAME}",
  "version": "${VERSION}",
  "timestamp": "$(date '+%Y-%m-%dT%H:%M:%S%z')",
  "hostname": "$(hostname 2>/dev/null || echo 'unknown')",
  "overall_status": ${overall_status},
  "overall_status_text": "$(case $overall_status in 0) echo "OK" ;; 1) echo "WARNING" ;; 2) echo "CRITICAL" ;; *) echo "UNKNOWN" ;; esac)",
  "thresholds": {
    "cpu_warning": ${CPU_WARNING},
    "cpu_critical": ${CPU_CRITICAL},
    "memory_warning": ${MEMORY_WARNING},
    "memory_critical": ${MEMORY_CRITICAL},
    "disk_warning": ${DISK_WARNING},
    "disk_critical": ${DISK_CRITICAL}
  },
  "checks": [
    {
      "component": "cpu",
      "usage": ${CPU_USAGE:-0},
      "status": "${CPU_STATUS}",
      "status_code": $(case "$CPU_STATUS" in "OK") echo 0 ;; "WARNING") echo 1 ;; "CRITICAL") echo 2 ;; *) echo 3 ;; esac),
      "message": "${CPU_RESULT}"
    },
    {
      "component": "memory",
      "usage": ${MEMORY_USAGE:-0},
      "status": "${MEMORY_STATUS}",
      "status_code": $(case "$MEMORY_STATUS" in "OK") echo 0 ;; "WARNING") echo 1 ;; "CRITICAL") echo 2 ;; *) echo 3 ;; esac),
      "message": "${MEMORY_RESULT}"
    },
    {
      "component": "disk",
      "usage": ${DISK_USAGE:-0},
      "status": "${DISK_STATUS}",
      "status_code": $(case "$DISK_STATUS" in "OK") echo 0 ;; "WARNING") echo 1 ;; "CRITICAL") echo 2 ;; *) echo 3 ;; esac),
      "message": "${DISK_RESULT}"
    }
  ]
}
EOF
}

# ==================== 报告生成 ====================

generate_report() {
    echo ""
    print_color "PURPLE" "=== 虚拟机健康检查报告 ==="
    echo "检查时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "主机名称: $(hostname 2>/dev/null || echo 'unknown')"
    echo "操作系统: $(uname -s) $(uname -r)"
    echo "脚本版本: ${VERSION}"
    echo "日志文件: ${LOG_FILE}"
    echo "使用的阈值配置:"
    echo "  CPU: 警告=${CPU_WARNING}%, 严重=${CPU_CRITICAL}%"
    echo "  内存: 警告=${MEMORY_WARNING}%, 严重=${MEMORY_CRITICAL}%"
    echo "  磁盘: 警告=${DISK_WARNING}%, 严重=${DISK_CRITICAL}%"
    echo ""
    
    echo "检查结果:"
    echo "----------------------------------------"
    
    # 执行检查
    check_cpu
    check_memory
    check_disk
    
    # 计算总体状态
    local overall_status=0
    case "$CPU_STATUS" in
        "CRITICAL") overall_status=2 ;;
        "WARNING") [ $overall_status -lt 1 ] && overall_status=1 ;;
    esac
    case "$MEMORY_STATUS" in
        "CRITICAL") overall_status=2 ;;
        "WARNING") [ $overall_status -lt 1 ] && overall_status=1 ;;
    esac
    case "$DISK_STATUS" in
        "CRITICAL") overall_status=2 ;;
        "WARNING") [ $overall_status -lt 1 ] && overall_status=1 ;;
    esac
    
    echo ""
    print_color "PURPLE" "=== 总体状态 ==="
    
    case $overall_status in
        0) print_color "GREEN" "✅ 系统健康状态良好，所有指标正常。" ;;
        1) print_color "YELLOW" "⚠️  系统存在警告，建议关注并处理。" ;;
        2) print_color "RED" "❌ 系统存在严重问题，请立即处理！" ;;
    esac
    
    echo "退出代码: ${overall_status} (0:正常, 1:警告, 2:严重)"
    
    return $overall_status
}

# ==================== 监控模式 ====================

monitor_mode() {
    local interval="${MONITOR_INTERVAL}"  # 使用全局变量
    local max_checks="${MAX_CHECKS}"
    local check_count=0
    
    echo ""
    print_color "GREEN" "📊 启动持续监控模式"
    echo "检查间隔: ${interval}秒"
    echo "倒计时刷新: ${COUNTDOWN_REFRESH}秒"
    echo "项目根目录: ${PROJECT_ROOT}"
    echo "按 Ctrl+C 停止监控"
    echo ""
    
    # 创建监控日志
    local monitor_log="${LOG_BASE_DIR}/monitor-$(date +%Y%m%d).log"
    echo "=== 监控开始 $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$monitor_log"
    echo "检查间隔: ${interval}秒" >> "$monitor_log"
    echo "倒计时刷新: ${COUNTDOWN_REFRESH}秒" >> "$monitor_log"
    echo "" >> "$monitor_log"
    
    while true; do
        check_count=$((check_count + 1))
        
        echo ""
        print_color "CYAN" "=== 监控检查 #${check_count} ==="
        echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
        
        # 执行检查
        check_cpu
        check_memory
        check_disk
        
        echo ""
        echo "📊 当前状态汇总:"
        echo "CPU: ${CPU_USAGE}% - ${CPU_STATUS}"
        echo "内存: ${MEMORY_USAGE}% - ${MEMORY_STATUS}"
        echo "磁盘: ${DISK_USAGE}% - ${DISK_STATUS}"
        
        # 写入监控日志
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] #${check_count} CPU=${CPU_USAGE}%(${CPU_STATUS}) 内存=${MEMORY_USAGE}%(${MEMORY_STATUS}) 磁盘=${DISK_USAGE}%(${DISK_STATUS})" >> "$monitor_log"
        
        # 检查是否达到最大检查次数
        if [ "$max_checks" -gt 0 ] && [ "$check_count" -ge "$max_checks" ]; then
            echo ""
            print_color "GREEN" "✅ 已完成 ${max_checks} 次检查，监控结束"
            echo "=== 监控结束 $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$monitor_log"
            echo "总检查次数: ${check_count}" >> "$monitor_log"
            break
        fi
        
        # 显示下次检查倒计时
        echo ""
        echo "下一轮检查将在 ${interval} 秒后开始..."
        
        # 根据刷新频率选择合适的倒计时方式
        if [ "$COUNTDOWN_REFRESH" -eq 1 ]; then
            # 1秒刷新使用简单的倒计时
            simple_countdown "$interval"
        elif [ "$COUNTDOWN_REFRESH" -gt 0 ] && [ "$interval" -gt "$COUNTDOWN_REFRESH" ]; then
            # 使用可配置刷新频率的倒计时
            countdown "$interval" "$COUNTDOWN_REFRESH"
        else
            # 默认简单的等待
            sleep "$interval"
        fi
    done
}

# ==================== 主函数 ====================

main() {
    start_time=$(date +%s)
    
    if [ "$JSON_OUTPUT" != true ]; then
        print_color "GREEN" "🚀 虚拟机健康检查开始..."
        echo "脚本: ${SCRIPT_NAME} v${VERSION}"
        echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
    fi
    
    # 确保日志目录存在
    mkdir -p "$LOG_BASE_DIR" 2>/dev/null || LOG_FILE="/dev/null"
    
    # 记录开始日志
    log_message "健康检查开始"
    
    # 执行检查
    if [ "$MONITOR_MODE" = true ]; then
        monitor_mode
        exit_code=0
    elif [ "$JSON_OUTPUT" = true ]; then
        generate_json_output
        exit_code=0
    else
        generate_report
        exit_code=$?
        
        if [ "$EXPLAIN_MODE" = true ]; then
            echo ""
            print_color "BLUE" "=== 详细解释 ==="
            echo "CPU阈值: 超过${CPU_WARNING}%警告，超过${CPU_CRITICAL}%严重"
            echo "内存阈值: 超过${MEMORY_WARNING}%警告，超过${MEMORY_CRITICAL}%严重"
            echo "磁盘阈值: 超过${DISK_WARNING}%警告，超过${DISK_CRITICAL}%严重"
        fi
    fi
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    if [ "$JSON_OUTPUT" != true ]; then
        echo ""
        print_color "PURPLE" "=== 执行统计 ==="
        echo "检查项目数: 3"
        echo "执行耗时: ${duration}秒"
        echo "日志文件: ${LOG_FILE}"
    fi
    
    log_message "健康检查完成，耗时${duration}秒"
    
    return ${exit_code:-0}
}

# ==================== 参数处理 ====================

parse_arguments() {
    # 先设置一个标志，表示是否通过命令行设置了监控间隔
    MONITOR_INTERVAL_SET=false
    
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
            -m|--monitor)
                MONITOR_MODE=true
                # 检查下一个参数是否是数字（间隔秒数）
                if [ -n "$2" ] && echo "$2" | grep -q "^[0-9][0-9]*$"; then
                    MONITOR_INTERVAL="$2"
                    MONITOR_INTERVAL_SET=true
                    shift
                fi
                ;;
            --max-checks)
                if [ -n "$2" ] && echo "$2" | grep -q "^[0-9][0-9]*$"; then
                    MAX_CHECKS="$2"
                    shift
                else
                    echo "错误: --max-checks 需要数字参数"
                    exit 1
                fi
                ;;
            --refresh)
                if [ -n "$2" ] && echo "$2" | grep -q "^[0-9][0-9]*$"; then
                    COUNTDOWN_REFRESH="$2"
                    shift
                    echo "设置倒计时刷新频率: ${COUNTDOWN_REFRESH}秒"
                else
                    echo "错误: --refresh 需要数字参数"
                    exit 1
                fi
                ;;
            -c|--config)
                if [ -n "$2" ]; then
                    CONFIG_FILE="$2"
                    case "$CONFIG_FILE" in
                        /*) ;;
                        *) CONFIG_FILE="${PROJECT_ROOT}/$CONFIG_FILE" ;;
                    esac
                    shift
                else
                    echo "错误: --config 需要配置文件路径"
                    exit 1
                fi
                ;;
            -l|--log)
                if [ -n "$2" ]; then
                    LOG_FILE="$2"
                    case "$LOG_FILE" in
                        /*) ;;
                        *) LOG_FILE="${PROJECT_ROOT}/$LOG_FILE" ;;
                    esac
                    shift
                else
                    echo "错误: --log 需要日志文件路径"
                    exit 1
                fi
                ;;
            -V|--verbose)
                VERBOSE=true
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

show_help() {
    cat << EOF
用法: $0 [选项]

虚拟机健康检查脚本 v${VERSION}

选项:
  -h, --help           显示此帮助信息
  -v, --version        显示版本信息
  -e, --explain        显示详细解释
  -j, --json           以JSON格式输出
  -m, --monitor [SEC]  持续监控模式（可选：检查间隔秒数，默认60）
  --max-checks NUM     最大检查次数（仅监控模式）
  --refresh SEC        倒计时刷新频率（秒，默认1）
  -c, --config FILE    指定配置文件路径（支持相对路径）
  -l, --log FILE       指定日志文件路径（支持相对路径）
  -V, --verbose        显示详细日志

示例:
  $0                    单次检查（使用默认配置）
  $0 --json             以JSON格式输出检查结果
  $0 --monitor          持续监控（默认60秒间隔）
  $0 --monitor 30       持续监控（30秒间隔）
  $0 --monitor 30 --refresh 2  监控30秒间隔，倒计时每2秒刷新
  $0 --monitor 30 --max-checks 10  监控30秒间隔，最多10次
  $0 --config my-config.conf 使用自定义配置
  $0 --log my.log       指定日志文件
  $0 --verbose          显示详细输出

配置文件: ${DEFAULT_CONFIG_FILE}
日志目录: ${LOG_BASE_DIR}
EOF
}

show_version() {
    echo "${SCRIPT_NAME} v${VERSION}"
}

# ==================== 执行入口 ====================

# 处理参数（这会设置MONITOR_INTERVAL_SET标志）
parse_arguments "$@"

# 加载配置
if [ -n "$CONFIG_FILE" ]; then
    load_config "$CONFIG_FILE"
else
    load_config "$DEFAULT_CONFIG_FILE"
fi

# 显示监控间隔信息
if [ "$MONITOR_MODE" = true ] && [ "$VERBOSE" = true ]; then
    if [ "$MONITOR_INTERVAL_SET" = true ]; then
        echo "使用命令行指定的检查间隔: ${MONITOR_INTERVAL}秒"
    else
        echo "使用配置文件中的检查间隔: ${MONITOR_INTERVAL}秒"
    fi
    echo "倒计时刷新频率: ${COUNTDOWN_REFRESH}秒"
fi

# 执行主函数
main