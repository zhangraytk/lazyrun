#!/bin/bash

# lazyrun - 智能后台任务管理器
# 作者: Ray, GitHub Copilot  
# 版本: 3.0
# 兼容: Linux, macOS
# 新特性: 智能命名，模块化设计，实时监控，标准化参数

# 确保调试模式关闭
set +x 2>/dev/null || true

# 版本信息
LAZYRUN_VERSION="3.0"
LAZYRUN_BUILD_DATE="2025-08-17"

# 配置变量
LAZYRUN_LOG_DIR="${HOME}/.lazyrun/logs"
LAZYRUN_PID_DIR="${HOME}/.lazyrun/pids"
PUSHPLUS_TOKEN="${PUSHPLUS_TOKEN:-}"  # 从环境变量获取，或手动设置
MIN_RUN_TIME="${MIN_RUN_TIME:-300}"  # 5分钟 = 300秒，可通过环境变量自定义
PUSHTITLE="${PUSHTITLE:-LazyRun任务通知}"
DEFAULT_SEARCH_DAYS=30  # 默认搜索天数
MAX_SEARCH_DAYS=90      # 最大搜索天数
# 创建必要的目录
mkdir -p "$LAZYRUN_LOG_DIR" "$LAZYRUN_PID_DIR"

# 颜色输出函数
print_color() {
    local color=$1
    local message=$2
    case $color in
        red)    echo -e "\033[31m$message\033[0m" ;;
        green)  echo -e "\033[32m$message\033[0m" ;;
        yellow) echo -e "\033[33m$message\033[0m" ;;
        blue)   echo -e "\033[36m$message\033[0m" ;;
        *)      echo "$message" ;;
    esac
}

# 获取系统时间戳
get_timestamp() {
    date +%s
}

# 格式化时间
format_time() {
    local timestamp=$1
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        date -r "$timestamp" "+%Y-%m-%d %H:%M:%S"
    else
        # Linux
        date -d "@$timestamp" "+%Y-%m-%d %H:%M:%S"
    fi
}

# 计算运行时间
calculate_duration() {
    local start_time=$1
    local end_time=$2
    local duration=$((end_time - start_time))
    
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    
    if [ $hours -gt 0 ]; then
        echo "${hours}小时${minutes}分钟${seconds}秒"
    elif [ $minutes -gt 0 ]; then
        echo "${minutes}分钟${seconds}秒"
    else
        echo "${seconds}秒"
    fi
}

# PushPlus推送函数
send_pushplus_notification() {
    local title="$1"
    local content="$2"
    local token="$3"
    
    if [ -z "$token" ]; then
        print_color yellow "警告: PUSHPLUS_TOKEN 未设置，跳过推送通知"
        return 1
    fi
    
    # 构建JSON数据
    local json_data
    json_data=$(cat << EOF
{
    "token": "$token",
    "title": "$PUSHTITLE",
    "content": "$content",
}
EOF
)
    echo ""
    print_color blue "📤 正在发送推送通知..."
    
    # 使用 curl 发送推送（兼容性最好）
    local response
    response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$json_data" \
        "http://www.pushplus.plus/send" 2>/dev/null)
    
    local curl_exit_code=$?
    
    if [ $curl_exit_code -eq 0 ]; then
        print_color green "✓ 推送通知已发送"
        print_color blue "📋 服务器响应: $response"
        return 0
    else
        print_color red "✗ 推送通知发送失败 (退出码: $curl_exit_code)"
        return 1
    fi
}

# 生成任务简称 - 改进版本
generate_task_name() {
    local cmd="$1"
    local first_arg=$(echo "$cmd" | awk '{print $1}')
    local second_arg=$(echo "$cmd" | awk '{print $2}')
    local base_name=""
    
    # 如果第一个参数是解释器（python, node等），使用第二个参数
    case "$first_arg" in
        python|python3|node|php|ruby|perl|bash|sh|zsh)
            if [ -n "$second_arg" ]; then
                local filename=$(basename "$second_arg")
                # 针对不同文件类型的处理
                case "$filename" in
                    *.py) base_name="${filename%.py}" ;;
                    *.js) base_name="${filename%.js}" ;;
                    *.php) base_name="${filename%.php}" ;;
                    *.rb) base_name="${filename%.rb}" ;;
                    *.pl) base_name="${filename%.pl}" ;;
                    *.sh) base_name="${filename%.sh}" ;;
                    ./*)
                        local clean_name="${filename#./}"
                        base_name="${clean_name%.*}"
                        ;;
                    *) base_name="${filename%.*}" ;;
                esac
            else
                base_name="$first_arg"
            fi
            ;;
        *)
            # 直接执行的文件
            local filename=$(basename "$first_arg")
            case "$filename" in
                *.sh) base_name="${filename%.sh}" ;;
                *.py) base_name="${filename%.py}" ;;
                *.js) base_name="${filename%.js}" ;;
                *.pl) base_name="${filename%.pl}" ;;
                *.rb) base_name="${filename%.rb}" ;;
                *.php) base_name="${filename%.php}" ;;
                ./*)
                    local clean_name="${filename#./}"
                    base_name="${clean_name%.*}"
                    ;;
                *) base_name="${filename%.*}" ;;
            esac
            ;;
    esac
    
    # 如果base_name为空或者只有特殊字符，使用默认名称
    if [ -z "$base_name" ] || [[ "$base_name" =~ ^[^a-zA-Z0-9_]+$ ]]; then
        base_name="task"
    fi
    
    # 清理非法字符，但保留更多有用字符
    base_name=$(echo "$base_name" | sed -E 's/[^a-zA-Z0-9_-]+/_/g; s/^_+|_+$//g')
    
    # 确保不为空
    if [ -z "$base_name" ]; then
        base_name="task"
    fi
    
    echo "$base_name"
}

# 后台运行函数
run_command_background() {
    local cmd="$1"
    
    # 使用新的任务名称生成函数
    local base_name=$(generate_task_name "$cmd")
    
    # 创建三级目录结构：年/月/日
    local year=$(date +%Y)
    local month=$(date +%m)
    local day=$(date +%d)
    local log_dir="$LAZYRUN_LOG_DIR/$year/$month/$day"
    
    # 新的日志文件命名：程序简称+年月日+时间+防重复后缀
    local date_str=$(date +%Y%m%d)
    local time_str=$(date +%H%M%S)
    local log_base="${base_name}_${date_str}_${time_str}"
    local counter=1
    local log_file="$log_dir/${log_base}.log"
    
    # 防止重复文件名
    while [ -f "$log_file" ]; do
        log_file="$log_dir/${log_base}_${counter}.log"
        counter=$((counter + 1))
    done
    
    local final_log_name=$(basename "$log_file" .log)
    local pid_file="$LAZYRUN_PID_DIR/${final_log_name}.pid"
    local start_time=$(get_timestamp)
    
    # 检查并创建三级目录结构
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
        print_color blue "📁 创建日志目录: $year/$month/$day"
    fi
    
    print_color blue "🚀 启动后台任务: $final_log_name"
    print_color blue "📅 日志路径: $year/$month/$day"
    print_color blue "📝 日志文件: $(basename "$log_file")"
    print_color blue "🔧 运行命令: $cmd"
    
    # 创建日志文件头部并立即写入
    {
        echo "================================================================================"
        echo "LazyRun 任务日志"
        echo "================================================================================"
        echo "任务名称: $final_log_name"
        echo "程序简称: $base_name"
        echo "开始时间: $(format_time $start_time)"
        echo "运行命令: $cmd"
        echo "系统信息: $(uname -s) $(uname -r)"
        echo "工作目录: $(pwd)"
        echo "================================================================================"
        echo ""
    } > "$log_file"
    
    # 在子shell中运行命令，使用nohup确保shell关闭后仍能运行
    export OSTYPE  # 显式导出OSTYPE变量，确保子shell可用
    
    # 创建临时脚本文件来避免复杂的引号嵌套
    local temp_script=$(mktemp)
    cat > "$temp_script" << 'SCRIPT_EOF'
set -e
# 设置陷阱处理信号
trap "exit 130" INT
trap "exit 143" TERM

# 记录PID和任务信息
echo $$ > "$TASK_PID_FILE"

# 实时写入日志开始标记
echo ">>> 命令开始执行: $(date '+%Y-%m-%d %H:%M:%S')" >> "$TASK_LOG_FILE"

# 使用 eval 执行命令，实时写入日志
if eval "$TASK_COMMAND" >> "$TASK_LOG_FILE" 2>&1; then
    exit_code=0
else
    exit_code=$?
fi

end_time=$(date +%s)
duration=$((end_time - TASK_START_TIME))

# 计算运行时间
hours=$((duration / 3600))
minutes=$(((duration % 3600) / 60))
seconds=$((duration % 60))

if [ $hours -gt 0 ]; then
    duration_text="${hours}小时${minutes}分钟${seconds}秒"
elif [ $minutes -gt 0 ]; then
    duration_text="${minutes}分钟${seconds}秒"
else
    duration_text="${seconds}秒"
fi

# 检查是否跨天运行，如果跨天则创建符号链接
if [[ "$OSTYPE" == "darwin"* ]]; then
    end_year=$(date -r $end_time +%Y 2>/dev/null)
    end_month=$(date -r $end_time +%m 2>/dev/null)  
    end_day=$(date -r $end_time +%d 2>/dev/null)
else
    end_year=$(date -d "@$end_time" +%Y 2>/dev/null)
    end_month=$(date -d "@$end_time" +%m 2>/dev/null)
    end_day=$(date -d "@$end_time" +%d 2>/dev/null)
fi

# 如果结束日期与开始日期不同，在结束日期目录创建符号链接
if [ "$end_year" != "$TASK_YEAR" ] || [ "$end_month" != "$TASK_MONTH" ] || [ "$end_day" != "$TASK_DAY" ]; then
    end_log_dir="$TASK_LOG_DIR/$end_year/$end_month/$end_day"
    mkdir -p "$end_log_dir"
    link_name="${TASK_FINAL_NAME}_crossday.log"
    ln -sf "$TASK_LOG_FILE" "$end_log_dir/$link_name" 2>/dev/null
    echo ">>> 跨天运行检测: 在 $end_year/$end_month/$end_day 创建日志链接" >> "$TASK_LOG_FILE"
fi

# 实时写入完成信息
{
    echo ""
    echo ">>> 命令执行完成: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ">>> 运行时长: $duration_text"
    echo ">>> 退出代码: $exit_code"
    echo "================================================================================"
} >> "$TASK_LOG_FILE"

# 检查是否需要发送通知
if [ $duration -ge $TASK_MIN_RUN_TIME ]; then
    if [ $exit_code -eq 0 ]; then
        task_status_text="✅ 成功完成"
    else
        task_status_text="❌ 执行失败 (退出码: $exit_code)"
    fi
    
    notification_title="LazyRun 任务完成: $TASK_FINAL_NAME"
    notification_content="任务名称: $TASK_FINAL_NAME
运行命令: $TASK_COMMAND
执行状态: $task_status_text
运行时长: $duration_text
完成时间: $(date '+%Y-%m-%d %H:%M:%S')
日志文件: $TASK_LOG_FILE"
    
    # 如果设置了PUSHPLUS_TOKEN，发送通知
    if [ -n "$TASK_PUSHPLUS_TOKEN" ]; then
        # 构建JSON数据
        json_data=$(cat << EOF
{
    "token": "$TASK_PUSHPLUS_TOKEN",
    "title": "$TASK_PUSHTITLE",
    "content": "$notification_content",
}
EOF
)
        # 使用 curl 发送推送（兼容性最好）
        response=$(curl -s -X POST \
            -H "Content-Type: application/json" \
            -d "$json_data" \
            "http://www.pushplus.plus/send" 2>/dev/null)
        
        if [ $? -eq 0 ]; then
            echo ">>> 推送通知已发送: $response" >> "$TASK_LOG_FILE"
        else
            echo ">>> 推送通知发送失败" >> "$TASK_LOG_FILE"
        fi
    fi
else
    echo ">>> 任务运行时间少于5分钟，跳过推送通知" >> "$TASK_LOG_FILE"
fi

# 清理PID文件和临时脚本
rm -f "$TASK_PID_FILE"
rm -f "$0"  # 删除临时脚本文件

exit $exit_code
SCRIPT_EOF
    
    # 设置环境变量供脚本使用
    export TASK_PID_FILE="$pid_file"
    export TASK_LOG_FILE="$log_file"
    export TASK_COMMAND="$cmd"
    export TASK_START_TIME="$start_time"
    export TASK_YEAR="$year"
    export TASK_MONTH="$month"
    export TASK_DAY="$day"
    export TASK_LOG_DIR="$LAZYRUN_LOG_DIR"
    export TASK_FINAL_NAME="$final_log_name"
    export TASK_MIN_RUN_TIME="$MIN_RUN_TIME"
    export TASK_PUSHPLUS_TOKEN="$PUSHPLUS_TOKEN"
    export TASK_PUSHTITLE="$PUSHTITLE"
    
    # 使用nohup执行临时脚本
    nohup bash "$temp_script" >/dev/null 2>&1 &
    
    local bg_pid=$!
    echo "🆔 后台进程PID: $bg_pid"
    echo "$bg_pid:$final_log_name:$start_time:$base_name" >> "$LAZYRUN_PID_DIR/active_jobs"
    echo ""
}

# 列出活跃任务 - 支持实时监控和详细显示
list_active_jobs() {
    local follow_mode=false
    local show_help=false
    local refresh_interval=3
    
    # 解析参数
    while [ $# -gt 0 ]; do
        case "$1" in
            -f|--follow)
                follow_mode=true
                shift
                ;;
            -i|--interval)
                if [ -n "$2" ] && [ "$2" -gt 0 ] 2>/dev/null; then
                    refresh_interval="$2"
                    shift 2
                else
                    print_color red "错误: 刷新间隔必须是正整数"
                    return 1
                fi
                ;;
            -h|--help)
                show_help=true
                shift
                ;;
            *)
                print_color red "错误: 未知参数 '$1'"
                show_help=true
                shift
                ;;
        esac
    done
    
    # 显示帮助信息
    if [ "$show_help" = true ]; then
        cat << 'EOF'
lazylist - 显示LazyRun任务状态

用法: lazylist [选项]

选项:
  -f, --follow         实时监控任务状态
  -i, --interval NUM   设置刷新间隔(秒，默认3秒)
  -h, --help           显示此帮助信息

示例:
  lazylist             显示当前活跃任务
  lazylist -f          实时监控任务(3秒刷新)
  lazylist -f -i 5     实时监控任务(5秒刷新)
EOF
        return 0
    fi
    
    # 检测操作系统类型，提高跨平台兼容性
    detect_os() {
        case "$(uname -s)" in
            Darwin*)    echo "macos" ;;
            Linux*)     echo "linux" ;;
            CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
            FreeBSD*)   echo "freebsd" ;;
            NetBSD*)    echo "netbsd" ;;
            OpenBSD*)   echo "openbsd" ;;
            *)          echo "unknown" ;;
        esac
    }
    
    # 获取进程信息 - 改进的跨平台兼容性
    get_process_info() {
        local pid="$1"
        local os_type
        local result
        
        # 检查进程是否存在
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "N/A:N/A:已停止"
            return 1
        fi
        
        os_type=$(detect_os)
        
        case "$os_type" in
            "macos")
                # macOS 使用不同的 ps 参数格式，更安全的处理方式
                result=$(ps -p "$pid" -o pcpu=,pmem=,state= 2>/dev/null | head -1 | awk '
                    {
                        cpu = ($1 == "" || $1 == 0) ? "0.0" : $1
                        mem = ($2 == "" || $2 == 0) ? "0.0" : $2
                        state = ($3 == "") ? "R" : $3
                        
                        # 清理数值并确保格式
                        gsub(/[^0-9.]/, "", cpu)
                        gsub(/[^0-9.]/, "", mem) 
                        if (cpu == "") cpu = "0.0"
                        if (mem == "") mem = "0.0"
                        
                        printf "%s%%:%s%%:%s", cpu, mem, state
                    }
                ')
                ;;
            "linux"|"freebsd"|"netbsd"|"openbsd")
                # Linux 和 BSD 系统，更安全的处理方式
                result=$(ps -p "$pid" -o pcpu,pmem,stat --no-headers 2>/dev/null | head -1 | awk '
                    {
                        cpu = ($1 == "" || $1 == 0) ? "0.0" : $1
                        mem = ($2 == "" || $2 == 0) ? "0.0" : $2
                        state = ($3 == "") ? "R" : substr($3, 1, 1)
                        
                        # 清理数值并确保格式
                        gsub(/[^0-9.]/, "", cpu)
                        gsub(/[^0-9.]/, "", mem)
                        if (cpu == "") cpu = "0.0"
                        if (mem == "") mem = "0.0"
                        
                        printf "%s%%:%s%%:%s", cpu, mem, state
                    }
                ')
                ;;
            *)
                # 未知系统，尝试基本的 ps 命令
                if ps -p "$pid" >/dev/null 2>&1; then
                    result="运行中:N/A:R"
                else
                    result="N/A:N/A:已停止"
                fi
                ;;
        esac
        
        # 确保有结果输出
        if [ -z "$result" ]; then
            result="N/A:N/A:已停止"
        fi
        
        echo "$result"
    }
    
    # 格式化进程状态为可读文本
    format_process_state() {
        case "$1" in
            "R") echo "运行中" ;;
            "S") echo "休眠" ;;
            "D") echo "等待IO" ;;
            "Z") echo "僵死" ;;
            "T") echo "已停止" ;;
            "I") echo "空闲" ;;
            "已停止") echo "已停止" ;;
            *) echo "$1" ;;
        esac
    }
    
    # 安全地截断文本，考虑中文字符
    truncate_text() {
        local text="$1"
        local max_len="$2"
        local suffix="..."
        
        # 简单的字符长度处理（不完美但兼容性好）
        if [ ${#text} -le "$max_len" ]; then
            echo "$text"
        else
            local keep_len=$((max_len - ${#suffix}))
            echo "${text:0:$keep_len}$suffix"
        fi
    }
    
    # 显示任务列表的主函数
    show_task_list() {
        # 临时保存并关闭所有可能的调试选项
        local old_set_state="$-"
        set +x +v +e 2>/dev/null || true
        
        local active_file="$LAZYRUN_PID_DIR/active_jobs"
        local temp_file
        local has_active_jobs=false
        local line_count=0
        
        if [ ! -f "$active_file" ]; then
            print_color yellow "📭 没有找到活跃的任务"
            return 1
        fi
        
        # 创建临时文件，提高安全性
        temp_file=$(mktemp "${TMPDIR:-/tmp}/lazyrun_jobs.XXXXXX" 2>/dev/null) || {
            print_color red "错误: 无法创建临时文件"
            return 1
        }
        
        # 显示标题
        print_color blue "🔄 LazyRun 活跃任务列表"
        echo ""
        
        # 表格头部 - 优化布局，提高可读性
        printf "┌─%-32s─┬─%-8s─┬─%-8s─┬─%-8s─┬─%-8s─┬─%-17s─┬─%-10s─┬─%-18s─┐\n" \
            "$(printf '─%.0s' {1..32})" "$(printf '─%.0s' {1..8})" \
            "$(printf '─%.0s' {1..8})" "$(printf '─%.0s' {1..8})" \
            "$(printf '─%.0s' {1..8})" "$(printf '─%.0s' {1..17})" \
            "$(printf '─%.0s' {1..10})" "$(printf '─%.0s' {1..18})"
        
        printf "│ %-32s │ %-8s │ %-8s │ %-8s │ %-8s │ %-17s │ %-10s │ %-18s │\n" \
            "任务名称" "PID" "CPU%" "内存%" "状态" "开始时间" "运行时长" "程序名"
        
        printf "├─%-32s─┼─%-8s─┼─%-8s─┼─%-8s─┼─%-8s─┼─%-17s─┼─%-10s─┼─%-18s─┤\n" \
            "$(printf '─%.0s' {1..32})" "$(printf '─%.0s' {1..8})" \
            "$(printf '─%.0s' {1..8})" "$(printf '─%.0s' {1..8})" \
            "$(printf '─%.0s' {1..8})" "$(printf '─%.0s' {1..17})" \
            "$(printf '─%.0s' {1..10})" "$(printf '─%.0s' {1..18})"
        
        # 处理每个任务
        {
        while IFS=':' read -r pid job_name start_time base_name || [ -n "$pid" ]; do
            # 严格校验字段完整性
            if [ -z "$pid" ] || [ -z "$job_name" ] || [ -z "$start_time" ] || [ -z "$base_name" ]; then
                continue
            fi
            
            # 检查进程是否仍在运行
            if kill -0 "$pid" 2>/dev/null; then
                has_active_jobs=true
                line_count=$((line_count + 1))
                
                # 计算运行时间 - 使用安全的变量赋值
                local current_time duration formatted_time
                current_time=$(get_timestamp 2>/dev/null)
                duration=$(calculate_duration "$start_time" "$current_time" 2>/dev/null)
                formatted_time=$(format_time "$start_time" 2>/dev/null || echo "未知时间")
                
                # 获取进程信息 - 使用安全的方式
                local proc_info cpu_usage mem_usage proc_state display_state
                proc_info=$(get_process_info "$pid" 2>/dev/null)
                cpu_usage=$(echo "$proc_info" | cut -d':' -f1 2>/dev/null)
                mem_usage=$(echo "$proc_info" | cut -d':' -f2 2>/dev/null)
                proc_state=$(echo "$proc_info" | cut -d':' -f3 2>/dev/null)
                display_state=$(format_process_state "$proc_state" 2>/dev/null)
                
                # 安全地截断显示文本
                local display_job_name display_base_name
                display_job_name=$(truncate_text "$job_name" 30)
                display_base_name=$(truncate_text "$base_name" 16)
                
                # 格式化并输出行
                printf "│ %-32s │ %-8s │ %-8s │ %-8s │ %-8s │ %-17s │ %-10s │ %-18s │\n" \
                    "$display_job_name" "$pid" "$cpu_usage" "$mem_usage" "$display_state" \
                    "${formatted_time:0:17}" "$duration" "$display_base_name"
                
                # 保存到临时文件
                printf "%s:%s:%s:%s\n" "$pid" "$job_name" "$start_time" "$base_name" >> "$temp_file"
            fi
        done < "$active_file"
        } 2>/dev/null
        
        # 表格底部
        printf "└─%-32s─┴─%-8s─┴─%-8s─┴─%-8s─┴─%-8s─┴─%-17s─┴─%-10s─┴─%-18s─┘\n" \
            "$(printf '─%.0s' {1..32})" "$(printf '─%.0s' {1..8})" \
            "$(printf '─%.0s' {1..8})" "$(printf '─%.0s' {1..8})" \
            "$(printf '─%.0s' {1..8})" "$(printf '─%.0s' {1..17})" \
            "$(printf '─%.0s' {1..10})" "$(printf '─%.0s' {1..18})"
        
        # 显示统计信息
        if [ "$has_active_jobs" = true ]; then
            echo ""
            print_color green "📊 共找到 $line_count 个活跃任务"
            
            # 更新活跃任务文件
            if [ -s "$temp_file" ]; then
                mv "$temp_file" "$active_file"
            else
                rm -f "$temp_file"
            fi
        else
            print_color yellow "📭 所有任务已完成"
            rm -f "$temp_file"
        fi
        
        return 0
    }
    
    # 信号处理，确保优雅退出
    trap 'echo ""; print_color blue "👋 监控已停止"; exit 0' INT TERM
    
    # 主执行逻辑
    if [ "$follow_mode" = true ]; then
        print_color green "🚀 启动实时监控模式 (刷新间隔: ${refresh_interval}秒)"
        echo ""
        
        # 持续监控循环
        while true; do
            # 清屏（仅在终端模式下）
            if [ -t 1 ] && command -v clear >/dev/null 2>&1; then
                clear
            fi
            
            # 显示监控头部信息
            print_color cyan "┌$(printf '─%.0s' {1..78})┐"
            printf "│ 📊 LazyRun 实时监控 - %-50s │\n" "$(date '+%Y-%m-%d %H:%M:%S')"
            print_color cyan "└$(printf '─%.0s' {1..78})┘"
            echo ""
            
            # 显示任务列表
            if ! show_task_list; then
                echo ""
                print_color yellow "⏳ 等待任务启动..."
            fi
            
            echo ""
            print_color blue "🔄 下次更新: ${refresh_interval}秒后 (按 Ctrl+C 退出监控)"
            
            # 等待指定间隔
            sleep "$refresh_interval"
        done
    else
        # 单次显示模式
        show_task_list
    fi
}

# 智能匹配活跃任务（用于lazykill）
find_matching_job() {
    local search_term="$1"
    local active_file="$LAZYRUN_PID_DIR/active_jobs"
    local matches=()
    local latest_job=""
    local latest_time=0
    
    if [ ! -f "$active_file" ]; then
        return 1
    fi
    
    # 收集所有匹配的任务
    while IFS=':' read -r pid task_name start_time base_name; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            # 完全匹配任务名
            if [ "$task_name" = "$search_term" ]; then
                echo "$task_name"
                return 0
            fi
            
            # 简称匹配（匹配base_name）
            if [ "$base_name" = "$search_term" ]; then
                matches+=("$task_name")
                # 记录最新的任务（基于启动时间）
                if [ "$start_time" -gt "$latest_time" ]; then
                    latest_time="$start_time"
                    latest_job="$task_name"
                fi
            fi
        fi
    done < "$active_file"
    
    # 如果有匹配的简称，返回最新的
    if [ ${#matches[@]} -gt 0 ]; then
        if [ ${#matches[@]} -gt 1 ]; then
            print_color blue "💡 找到 ${#matches[@]} 个匹配的活跃任务，选择最新的: $latest_job"
            print_color yellow "   其他匹配: ${matches[*]}"
        fi
        echo "$latest_job"
        return 0
    fi
    
    return 1
}

# 新的智能日志匹配函数（用于lazylog）- 重写优化版本
smart_log_search() {
    local search_term="$1"
    local max_days="${2:-$DEFAULT_SEARCH_DAYS}"
    
    # 输入验证
    if [ -z "$search_term" ]; then
        print_color red "错误: 搜索词不能为空" >&2
        return 1
    fi
    
    # 判断搜索模式 - 使用更精确的匹配
    if echo "$search_term" | grep -q '_[0-9]\{8\}_[0-9]\{6\}'; then
        # 完整日志名模式：包含完整时间戳
        path_based_log_search "$search_term"
    elif echo "$search_term" | grep -q '_[0-9]\{8\}'; then
        # 日期匹配模式：包含日期但可能不完整
        path_based_log_search "$search_term"
    else
        # 智能匹配模式：基于程序简称搜索
        intelligent_log_search "$search_term" "$max_days"
    fi
}

# 路径匹配搜索（用于完整日志名）- 重写优化版本
path_based_log_search() {
    local search_term="$1"
    local found_files=()
    
    # 使用更高效的日期提取方法
    local date_part=""
    if echo "$search_term" | grep -q '_[0-9]\{8\}'; then
        date_part=$(echo "$search_term" | sed -n 's/.*_\([0-9]\{8\}\).*/\1/p' | head -1)
    fi
    
    if [ -n "$date_part" ] && [ ${#date_part} -eq 8 ]; then
        # 从日期字符串提取年月日
        local year="${date_part:0:4}"
        local month="${date_part:4:2}"
        local day="${date_part:6:2}"
        local search_dir="$LAZYRUN_LOG_DIR/$year/$month/$day"
        
        if [ -d "$search_dir" ]; then
            # 精确匹配和模糊匹配
            _search_in_directory "$search_dir" "$search_term" found_files
        fi
    else
        # 无日期信息，全局搜索（使用find优化性能）
        _global_log_search "$search_term" found_files
    fi
    
    # 处理搜索结果
    _handle_search_results found_files[@]
}

# 在指定目录中搜索日志文件
_search_in_directory() {
    local search_dir="$1"
    local search_term="$2"
    local -n files_ref=$3
    
    # 精确匹配
    if [ -f "${search_dir}/${search_term}.log" ]; then
        files_ref+=("${search_dir}/${search_term}.log")
        return
    fi
    
    # 前缀匹配（使用find提高效率）
    while IFS= read -r -d '' file; do
        files_ref+=("$file")
    done < <(find "$search_dir" -maxdepth 1 -name "${search_term}*.log" -type f -print0 2>/dev/null)
    
    # 如果还是没找到，尝试包含匹配
    if [ ${#files_ref[@]} -eq 0 ]; then
        while IFS= read -r -d '' file; do
            local basename_file=$(basename "$file" .log)
            if [ "${basename_file#*$search_term}" != "$basename_file" ]; then
                files_ref+=("$file")
            fi
        done < <(find "$search_dir" -maxdepth 1 -name "*.log" -type f -print0 2>/dev/null)
    fi
}

# 全局日志搜索
_global_log_search() {
    local search_term="$1"
    local -n files_ref=$2
    
    # 使用find进行高效的全局搜索
    while IFS= read -r -d '' file; do
        files_ref+=("$file")
    done < <(find "$LAZYRUN_LOG_DIR" -name "${search_term}*.log" -type f -print0 2>/dev/null | head -20)
    
    # 如果没找到前缀匹配，尝试包含匹配（限制结果数量）
    if [ ${#files_ref[@]} -eq 0 ]; then
        while IFS= read -r -d '' file; do
            local basename_file=$(basename "$file" .log)
            if [ "${basename_file#*$search_term}" != "$basename_file" ]; then
                files_ref+=("$file")
                # 限制结果数量避免性能问题
                if [ ${#files_ref[@]} -ge 20 ]; then
                    break
                fi
            fi
        done < <(find "$LAZYRUN_LOG_DIR" -name "*.log" -type f -print0 2>/dev/null)
    fi
}

# 处理搜索结果
_handle_search_results() {
    local -n files_ref=$1
    local found_files=("${files_ref[@]}")
    
    case ${#found_files[@]} in
        0)
            return 1
            ;;
        1)
            echo "${found_files[0]}"
            return 0
            ;;
        *)
            _show_file_selection_menu found_files[@]
            return $?
            ;;
    esac
}

# 显示文件选择菜单
_show_file_selection_menu() {
    local -n files_ref=$1
    local found_files=("${files_ref[@]}")
    
    print_color yellow "找到 ${#found_files[@]} 个匹配的日志文件:" >&2
    print_color blue "请选择要查看的日志文件:" >&2
    
    # 按修改时间排序文件
    local sorted_files=()
    while IFS= read -r -d '' file; do
        sorted_files+=("$file")
    done < <(printf '%s\0' "${found_files[@]}" | xargs -0 ls -t 2>/dev/null | head -10 | tr '\n' '\0')
    
    # 显示选择菜单
    local i=1
    for file in "${sorted_files[@]}"; do
        local file_name=$(basename "$file")
        local file_date=""
        # 跨平台的日期提取
        if [[ "$OSTYPE" == "darwin"* ]]; then
            file_date=$(stat -f %Sm -t "%Y-%m-%d %H:%M" "$file" 2>/dev/null || echo "未知")
        else
            file_date=$(stat -c %y "$file" 2>/dev/null | cut -d. -f1 || echo "未知")
        fi
        printf "  %d) %s (%s)\n" "$i" "$file_name" "$file_date" >&2
        ((i++))
        # 限制显示数量
        if [ $i -gt 10 ]; then
            print_color yellow "  ... 还有 $((${#found_files[@]} - 10)) 个文件未显示" >&2
            break
        fi
    done
    
    # 交互式选择
    if [ -t 0 ] && [ -t 2 ]; then
        printf "请输入序号 (1-%d) 或 'q' 退出: " "${#sorted_files[@]}" >&2
        local choice
        read choice </dev/tty 2>/dev/null || choice="q"
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#sorted_files[@]}" ]; then
            echo "${sorted_files[$((choice-1))]}"
            return 0
        elif [ "$choice" = "q" ] || [ "$choice" = "Q" ]; then
            print_color yellow "用户取消选择" >&2
            return 1
        else
            print_color red "无效的选择: $choice" >&2
            return 1
        fi
    else
        print_color yellow "非交互式环境，自动选择最新的日志文件" >&2
        echo "${sorted_files[0]}"
        return 0
    fi
}

# 智能匹配搜索（用于程序简称）- 重写优化版本
intelligent_log_search() {
    local base_name="$1"
    local max_days="$2"
    
    # 输入验证
    if [ -z "$base_name" ] || ! [[ "$max_days" =~ ^[0-9]+$ ]]; then
        print_color red "错误: 无效的搜索参数" >&2
        return 1
    fi
    
    # 从今天开始向前搜索，找到即停止
    for ((i=0; i<max_days; i++)); do
        local date_info
        date_info=$(_get_date_offset "$i")
        
        if [ $? -ne 0 ] || [ -z "$date_info" ]; then
            continue
        fi
        
        local year month day
        IFS='|' read -r year month day <<< "$date_info"
        
        local search_dir="$LAZYRUN_LOG_DIR/$year/$month/$day"
        
        # 如果该日期目录存在，查找匹配的日志文件
        if [ -d "$search_dir" ]; then
            # 使用find进行高效搜索，按修改时间排序
            local latest_file
            latest_file=$(find "$search_dir" -name "${base_name}_*.log" -type f -exec ls -t {} + 2>/dev/null | head -1)
            
            if [ -n "$latest_file" ] && [ -f "$latest_file" ]; then
                echo "$latest_file"
                return 0
            fi
        fi
    done
    
    # 如果在默认天数内没找到，询问用户是否继续搜索
    if [ "$max_days" -eq "$DEFAULT_SEARCH_DAYS" ] && [ -t 0 ] && [ -t 2 ]; then
        print_color yellow "在最近 $DEFAULT_SEARCH_DAYS 天内未找到匹配的日志" >&2
        printf "是否继续搜索更久远的日志？(y/N): " >&2
        
        local reply
        read reply </dev/tty 2>/dev/null || reply="n"
        
        case "$reply" in
            [Yy]|[Yy][Ee][Ss])
                intelligent_log_search "$base_name" "$MAX_SEARCH_DAYS"
                return $?
                ;;
        esac
    fi
    
    return 1
}

# 跨平台日期计算函数
_get_date_offset() {
    local days_ago="$1"
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS - 使用BSD date
        local year month day
        year=$(date -v-${days_ago}d +%Y 2>/dev/null) || return 1
        month=$(date -v-${days_ago}d +%m 2>/dev/null) || return 1
        day=$(date -v-${days_ago}d +%d 2>/dev/null) || return 1
        echo "$year|$month|$day"
    else
        # Linux - 使用GNU date
        local year month day
        year=$(date -d "$days_ago days ago" +%Y 2>/dev/null) || return 1
        month=$(date -d "$days_ago days ago" +%m 2>/dev/null) || return 1
        day=$(date -d "$days_ago days ago" +%d 2>/dev/null) || return 1
        echo "$year|$month|$day"
    fi
}

# 改进的终止任务函数 - 合并lazykill和lazykillall功能
kill_job() {
    local target_job="$1"
    local kill_all=false
    
    # 处理帮助参数
    if [ "$target_job" = "--help" ] || [ "$target_job" = "-h" ]; then
        cat << 'EOF'
lazykill - 终止LazyRun任务

用法: lazykill [选项] [任务名]

选项:
  -a, --all       终止所有任务
  -h, --help      显示帮助

示例:
  lazykill train    终止train任务
  lazykill -a       终止所有任务
EOF
        return 0
    fi
    
    # 检查是否是 -a 参数
    if [ "$target_job" = "-a" ] || [ "$target_job" = "--all" ]; then
        kill_all=true
    elif [ -z "$target_job" ]; then
        print_color red "错误: 请指定要终止的任务名或使用 -a 终止所有任务"
        print_color blue "使用 'lazylist' 查看活跃任务"
        print_color blue "使用 'lazykill --help' 查看帮助信息"
        return 1
    fi
    
    local active_file="$LAZYRUN_PID_DIR/active_jobs"
    
    if [ ! -f "$active_file" ]; then
        print_color red "没有找到活跃的任务"
        return 1
    fi
    
    if [ "$kill_all" = true ]; then
        # 终止所有任务
        print_color yellow "正在终止所有 LazyRun 任务..."
        
        local killed_count=0
        while IFS=':' read -r pid job_name start_time base_name; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                print_color blue "终止任务: $job_name (PID: $pid)"
                kill -TERM "$pid" 2>/dev/null
                ((killed_count++))
            fi
        done < "$active_file"
        
        if [ $killed_count -eq 0 ]; then
            print_color yellow "没有找到活跃的任务"
            return 0
        fi
        
        # 等待优雅终止
        print_color blue "等待任务优雅退出..."
        sleep 3
        
        # 强制终止仍在运行的进程
        local force_killed=0
        while IFS=':' read -r pid job_name start_time base_name; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                print_color yellow "强制终止: $job_name (PID: $pid)"
                kill -KILL "$pid" 2>/dev/null
                ((force_killed++))
            fi
        done < "$active_file"
        
        # 清理文件
        rm -f "$active_file"
        rm -f "$LAZYRUN_PID_DIR"/*.pid
        
        if [ $force_killed -gt 0 ]; then
            print_color green "✓ 所有任务已终止 (${killed_count}个正常终止，${force_killed}个强制终止)"
        else
            print_color green "✓ 所有${killed_count}个任务已正常终止"
        fi
        return 0
    fi
    
    # 终止指定任务
    local found=false
    
    # 使用智能匹配查找任务
    local matched_job=$(find_matching_job "$target_job")
    if [ -z "$matched_job" ]; then
        print_color red "未找到任务: $target_job"
        print_color blue "当前活跃任务:"
        list_active_jobs
        return 1
    fi
    
    local temp_file=$(mktemp)
    
    while IFS=':' read -r pid task_name start_time base_name; do
        if [ "$task_name" = "$matched_job" ]; then
            found=true
            if kill -0 "$pid" 2>/dev/null; then
                print_color yellow "正在终止任务: $task_name (PID: $pid)"
                
                # 首先尝试优雅终止
                kill -TERM "$pid" 2>/dev/null
                sleep 2
                
                # 如果还在运行，强制终止
                if kill -0 "$pid" 2>/dev/null; then
                    print_color yellow "强制终止任务..."
                    kill -KILL "$pid" 2>/dev/null
                fi
                
                # 清理PID文件
                rm -f "$LAZYRUN_PID_DIR/${task_name}.pid"
                
                print_color green "✓ 任务 '$task_name' 已终止"
            else
                print_color yellow "任务 '$task_name' 已经结束"
            fi
        else
            echo "$pid:$task_name:$start_time:$base_name" >> "$temp_file"
        fi
    done < "$active_file"
    
    mv "$temp_file" "$active_file"
}

# 改进的日志查看函数 - 合并lazylog和lazylogs功能
view_job_log() {
    local search_term="$1"
    local action="${2:-}"
    
    # 处理帮助参数
    if [ "$search_term" = "--help" ] || [ "$action" = "--help" ]; then
        cat << 'EOF'
lazylog - 查看LazyRun日志

用法: lazylog [选项] [任务名] [动作]

选项:
  -d, --day <天数>    显示指定天数内日志
  -h, --help          显示帮助

动作:
  tail         显示最后50行 (默认)
  cat          编辑器查看完整日志
  follow       实时跟踪日志

示例:
  lazylog            交互选择日志
  lazylog train      查看train任务日志
  lazylog train cat  编辑器查看
  lazylog -d 7       显示近7天日志
  lazylog --day 14   显示近14天日志
EOF
        return 0
    fi
    
    # 如果没有提供搜索词，显示近期日志列表并提供交互选择
    if [ -z "$search_term" ]; then
        show_recent_logs_interactive
        return $?
    fi
    
    # 处理特殊参数
    case "$search_term" in
        -d|--day)
            # -d/--day 参数：显示指定天数的日志
            local days="${2:-7}"
            if ! [[ "$days" =~ ^[0-9]+$ ]]; then
                print_color red "错误: -d/--day 参数后必须跟数字"
                return 1
            fi
            list_logs_by_days "$days"
            return $?
            ;;
        tail|cat|follow)
            # 如果第一个参数是动作，提示用户
            print_color red "错误: 请先指定任务名称"
            print_color blue "用法: lazylog <任务名称> [tail|cat|follow]"
            return 1
            ;;
    esac
    
    # 处理动作参数
    case "$action" in
        tail|"")
            action="tail"
            ;;
        cat)
            action="cat"
            ;;
        follow)
            action="follow"
            ;;
        -d)
            # 如果第二个参数是-d，后面应该跟天数
            local days="${3:-7}"
            if ! [[ "$days" =~ ^[0-9]+$ ]]; then
                print_color red "错误: -d 参数后必须跟数字"
                return 1
            fi
            list_logs_by_days "$days" "$search_term"
            return $?
            ;;
        *)
            if [ -n "$action" ]; then
                print_color red "错误: 未知的日志查看模式 '$action'"
                print_color blue "支持的模式: tail, cat, follow"
                return 1
            fi
            ;;
    esac
    
    # 使用智能匹配查找日志文件
    local log_file=$(smart_log_search "$search_term")
    
    if [ -z "$log_file" ] || [ ! -f "$log_file" ]; then
        print_color red "未找到匹配的日志文件: $search_term"
        print_color blue "使用 'lazylog' (无参数) 查看近期任务并交互选择"
        return 1
    fi
    
    print_color blue "📖 查看日志文件: $(basename "$log_file")"
    print_color green "完整路径: $log_file"
    
    # 选择编辑器查看日志
    case "$action" in
        tail)
            print_color green "显示最后50行日志:"
            tail -50 "$log_file"
            ;;
        cat)
            print_color green "显示完整日志:"
            # 优先使用nano，找不到则使用vim
            if command -v nano >/dev/null 2>&1; then
                print_color blue "使用nano查看日志 (Ctrl+X 退出):"
                nano "$log_file"
            elif command -v vim >/dev/null 2>&1; then
                print_color blue "使用vim查看日志 (:q 退出):"
                vim "$log_file"
            else
                print_color yellow "未找到nano或vim，使用cat显示:"
                cat "$log_file"
            fi
            ;;
        follow)
            print_color green "实时跟踪日志 (Ctrl+C 退出):"
            tail -f "$log_file"
            ;;
    esac
}

# 显示近期日志并提供交互选择
show_recent_logs_interactive() {
    print_color blue "📚 近10个任务日志:"
    
    if [ ! -d "$LAZYRUN_LOG_DIR" ]; then
        print_color yellow "日志目录不存在"
        return 1
    fi
    
    # 收集近期日志文件
    local log_files=()
    local log_info=()
    
    # 查找所有日志文件并按修改时间排序
    while IFS= read -r -d '' log_file; do
        if [ -f "$log_file" ]; then
            log_files+=("$log_file")
            
            # 提取文件信息
            local file_name=$(basename "$log_file")
            local program_name=$(echo "$file_name" | sed -E 's/_[0-9]{8}_[0-9]{6}(_[0-9]+)?\.log$//')
            local file_date=""
            # 从路径中提取日期
            file_date=$(echo "$log_file" | grep -o '/[0-9]\{4\}/[0-9]\{2\}/[0-9]\{2\}/' | tr -d '/' | sed 's/\(.*\)\(..\)\(..\)/\1-\2-\3/')
            log_info+=("$program_name ($file_date)")
        fi
    done < <(find "$LAZYRUN_LOG_DIR" -name "*.log" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -10 | tr '\n' '\0')
    
    if [ ${#log_files[@]} -eq 0 ]; then
        print_color yellow "没有找到任何日志文件"
        return 1
    fi
    
    # 显示选择菜单
    local i=1
    for info in "${log_info[@]}"; do
        printf "  %d) %s\n" "$i" "$info"
        ((i++))
    done
    echo
    
    # 交互式选择
    if [ -t 0 ] && [ -t 1 ]; then
        printf "请输入序号 (1-%d) 或 'q' 退出: " "${#log_files[@]}"
        local choice
        read choice || choice="q"
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#log_files[@]}" ]; then
            local selected_file="${log_files[$((choice-1))]}"
            print_color blue "📖 查看日志文件: $(basename "$selected_file")"
            print_color green "完整路径: $selected_file"
            
            # 优先使用nano，找不到则使用vim
            if command -v nano >/dev/null 2>&1; then
                print_color blue "使用nano查看日志 (Ctrl+X 退出):"
                nano "$selected_file"
            elif command -v vim >/dev/null 2>&1; then
                print_color blue "使用vim查看日志 (:q 退出):"
                vim "$selected_file"
            else
                print_color yellow "未找到nano或vim，使用less查看:"
                less "$selected_file"
            fi
            return 0
        elif [ "$choice" = "q" ] || [ "$choice" = "Q" ]; then
            print_color yellow "用户取消选择"
            return 1
        else
            print_color red "无效的选择: $choice"
            return 1
        fi
    else
        print_color yellow "非交互式环境，显示最新的日志文件"
        tail -50 "${log_files[0]}"
        return 0
    fi
}

# 按天数列出日志
list_logs_by_days() {
    local days="${1:-7}"
    local task_filter="${2:-}"
    
    print_color blue "📚 近${days}天的任务日志:"
    
    if [ ! -d "$LAZYRUN_LOG_DIR" ]; then
        print_color yellow "日志目录不存在"
        return 1
    fi
    
    printf "%-12s %-25s %-15s %-25s\n" "日期" "任务名称" "日志文件数" "最新日志"
    echo "--------------------------------------------------------------------------------"
    
    local found_logs=false
    
    # 遍历指定天数
    for ((i=0; i<days; i++)); do
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            local check_date=$(date -v-${i}d +%Y%m%d)
            local display_date=$(date -v-${i}d +%Y/%m/%d)
            local year=$(date -v-${i}d +%Y)
            local month=$(date -v-${i}d +%m)
            local day=$(date -v-${i}d +%d)
        else
            # Linux
            local check_date=$(date -d "$i days ago" +%Y%m%d)
            local display_date=$(date -d "$i days ago" +%Y/%m/%d)
            local year=$(date -d "$i days ago" +%Y)
            local month=$(date -d "$i days ago" +%m)
            local day=$(date -d "$i days ago" +%d)
        fi
        
        local day_dir="$LAZYRUN_LOG_DIR/$year/$month/$day"
        
        if [ -d "$day_dir" ]; then
            # 统计该日期的任务（按程序名称分组）
            local processed_programs=()
            
            for log_file in "$day_dir"/*.log; do
                if [ -f "$log_file" ]; then
                    local file_name=$(basename "$log_file")
                    # 提取程序名称（日志文件格式：程序名_YYYYMMDD_HHMMSS[_counter].log）
                    local program_name=$(echo "$file_name" | sed -E 's/_[0-9]{8}_[0-9]{6}(_[0-9]+)?\.log$//')
                    
                    # 如果指定了任务过滤器，检查是否匹配
                    if [ -n "$task_filter" ] && [[ "$program_name" != *"$task_filter"* ]]; then
                        continue
                    fi
                    
                    # 检查程序是否已经处理过
                    local already_processed=false
                    for processed_program in "${processed_programs[@]}"; do
                        if [ "$processed_program" = "$program_name" ]; then
                            already_processed=true
                            break
                        fi
                    done
                    
                    if [ "$already_processed" = false ]; then
                        processed_programs+=("$program_name")
                        found_logs=true
                        
                        # 统计该程序当天的日志数
                        local log_count=$(ls "$day_dir"/${program_name}_${check_date}_*.log 2>/dev/null | wc -l)
                        local latest_log=$(ls -t "$day_dir"/${program_name}_${check_date}_*.log 2>/dev/null | head -1)
                        local latest_name=""
                        
                        if [ -n "$latest_log" ]; then
                            latest_name=$(basename "$latest_log")
                        fi
                        
                        printf "%-12s %-25s %-15s %-25s\n" "$display_date" "$program_name" "$log_count 个文件" "$latest_name"
                    fi
                fi
            done
        fi
    done
    
    if [ "$found_logs" = false ]; then
        if [ -n "$task_filter" ]; then
            print_color yellow "近${days}天没有找到任务 '${task_filter}' 的日志文件"
        else
            print_color yellow "近${days}天没有找到任何日志文件"
        fi
        return 1
    fi
}

# 测试PushPlus推送功能
test_pushplus() {
    local token="$1"
    
    if [ -z "$token" ]; then
        token="$PUSHPLUS_TOKEN"
        if [ -z "$token" ]; then
            print_color red "错误: 请提供PushPlus token"
            print_color blue "用法: test_pushplus <token>"
            print_color blue "或设置环境变量: export PUSHPLUS_TOKEN='your_token'"
            return 1
        fi
    fi
    
    print_color blue "🧪 测试PushPlus推送功能..."
    print_color blue "📱 Token: ${token:0:10}..."
    
    local test_content="这是一条来自LazyRun的测试推送消息
    
测试时间: $(date '+%Y-%m-%d %H:%M:%S')
系统信息: $(uname -s) $(uname -r)
工作目录: $(pwd)

如果您收到这条消息，说明PushPlus推送功能配置正确！✅"
    
    send_pushplus_notification "LazyRun测试" "$test_content" "$token"
}

# 清理日志功能（仅支持新的年/月/日格式）
clean_logs() {
    local days_ago="$1"
    local task_name="$2"
    
    # 处理帮助参数
    if [ "$days_ago" = "--help" ] || [ "$days_ago" = "-h" ]; then
        cat << 'EOF'
lazyclean - 清理LazyRun日志

用法: lazyclean [选项] [天数] [任务名]

选项:
  -h, --help      显示帮助

参数:
  天数            清理多少天前的日志 (默认: 7)
  任务名          只清理指定任务的日志 (可选)

示例:
  lazyclean           清理7天前的所有日志
  lazyclean 30        清理30天前的所有日志
  lazyclean 7 train   清理7天前的train任务日志
EOF
        return 0
    fi
    
    # 默认清理7天前的日志
    if [ -z "$days_ago" ]; then
        days_ago=7
    fi
    
    # 验证天数是否为数字
    if ! [[ "$days_ago" =~ ^[0-9]+$ ]]; then
        print_color red "错误: 天数必须是正整数"
        return 1
    fi
    
    print_color blue "🧹 清理 $days_ago 天前的日志..."
    
    local cleaned_count=0
    local total_size=0
    
    if [ -n "$task_name" ]; then
        # 清理特定任务的日志（仅在年/月/日目录结构中查找）
        print_color blue "📁 清理任务 '$task_name' 的日志..."
        local found_task=false
        
        # 遍历年份目录
        for year_dir in "$LAZYRUN_LOG_DIR"/*/; do
            if [ -d "$year_dir" ]; then
                local year_name=$(basename "$year_dir")
                
                # 检查是否是年份目录 (YYYY)
                if [[ "$year_name" =~ ^[0-9]{4}$ ]]; then
                    # 遍历月份目录
                    for month_dir in "$year_dir"/*/; do
                        if [ -d "$month_dir" ]; then
                            local month_name=$(basename "$month_dir")
                            
                            # 遍历日期目录
                            for day_dir in "$month_dir"/*/; do
                                if [ -d "$day_dir" ]; then
                                    local day_name=$(basename "$day_dir")
                                    local date_str="$year_name/$month_name/$day_name"
                                    
                                    # 查找匹配的任务日志文件
                                    for log_file in "$day_dir"/*.log; do
                                        if [ -f "$log_file" ]; then
                                            local file_name=$(basename "$log_file")
                                            # 新格式：程序名_YYYYMMDD_HHMMSS[_counter].log
                                            local program_name=$(echo "$file_name" | sed -E 's/_[0-9]{8}_[0-9]{6}(_[0-9]+)?\.log$//')
                                            
                                            if [[ "$program_name" == *"$task_name"* ]] || [ "$program_name" = "$task_name" ]; then
                                                found_task=true
                                                
                                                # 检查文件是否超过指定天数
                                                local file_time=$(stat -f%m "$log_file" 2>/dev/null || stat -c%Y "$log_file" 2>/dev/null || echo 0)
                                                local current_time=$(date +%s)
                                                local days_diff=$(( (current_time - file_time) / 86400 ))
                                                
                                                if [ $days_diff -gt $days_ago ]; then
                                                    local file_size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0)
                                                    total_size=$((total_size + file_size))
                                                    rm -f "$log_file"
                                                    cleaned_count=$((cleaned_count + 1))
                                                    print_color yellow "  删除: $date_str/$(basename "$log_file")"
                                                fi
                                            fi
                                        fi
                                    done
                                fi
                            done
                        fi
                    done
                fi
            fi
        done
        
        if [ "$found_task" = false ]; then
            print_color red "错误: 没有找到任务 '$task_name' 的日志"
            return 1
        fi
    else
        # 清理所有任务的日志
        if [ ! -d "$LAZYRUN_LOG_DIR" ]; then
            print_color yellow "日志目录不存在，无需清理"
            return 0
        fi
        
        print_color blue "📁 清理所有任务的日志..."
        
        # 遍历年份目录
        for year_dir in "$LAZYRUN_LOG_DIR"/*/; do
            if [ -d "$year_dir" ]; then
                local year_name=$(basename "$year_dir")
                
                # 检查是否是年份目录 (YYYY)
                if [[ "$year_name" =~ ^[0-9]{4}$ ]]; then
                    print_color blue "处理年份: $year_name"
                    
                    # 遍历月份目录
                    for month_dir in "$year_dir"/*/; do
                        if [ -d "$month_dir" ]; then
                            local month_name=$(basename "$month_dir")
                            
                            # 遍历日期目录
                            for day_dir in "$month_dir"/*/; do
                                if [ -d "$day_dir" ]; then
                                    local day_name=$(basename "$day_dir")
                                    local date_str="$year_name/$month_name/$day_name"
                                    print_color blue "  处理日期: $date_str"
                                    
                                    # 查找并删除旧日志
                                    while IFS= read -r -d '' log_file; do
                                        local file_size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0)
                                        total_size=$((total_size + file_size))
                                        rm -f "$log_file"
                                        cleaned_count=$((cleaned_count + 1))
                                        print_color yellow "    删除: $date_str/$(basename "$log_file")"
                                    done < <(find "$day_dir" -name "*.log" -mtime +$days_ago -print0 2>/dev/null)
                                    
                                    # 如果日期目录为空，删除日期目录
                                    if [ -d "$day_dir" ] && [ -z "$(ls -A "$day_dir" 2>/dev/null)" ]; then
                                        rmdir "$day_dir"
                                        print_color blue "🗑️    删除空日期目录: $date_str"
                                    fi
                                fi
                            done
                            
                            # 如果月份目录为空，删除月份目录
                            if [ -d "$month_dir" ] && [ -z "$(ls -A "$month_dir" 2>/dev/null)" ]; then
                                rmdir "$month_dir"
                                print_color blue "🗑️  删除空月份目录: $year_name/$month_name"
                            fi
                        fi
                    done
                    
                    # 如果年份目录为空，删除年份目录
                    if [ -d "$year_dir" ] && [ -z "$(ls -A "$year_dir" 2>/dev/null)" ]; then
                        rmdir "$year_dir"
                        print_color blue "🗑️删除空年份目录: $year_name"
                    fi
                fi
            fi
        done
    fi
    
    # 转换文件大小为可读格式
    local size_text
    if [ $total_size -gt 1073741824 ]; then
        size_text="$(echo "scale=2; $total_size/1073741824" | bc 2>/dev/null || echo "0")GB"
    elif [ $total_size -gt 1048576 ]; then
        size_text="$(echo "scale=2; $total_size/1048576" | bc 2>/dev/null || echo "0")MB"
    elif [ $total_size -gt 1024 ]; then
        size_text="$(echo "scale=2; $total_size/1024" | bc 2>/dev/null || echo "0")KB"
    else
        size_text="${total_size}B"
    fi
    
    if [ $cleaned_count -gt 0 ]; then
        print_color green "✅ 清理完成!"
        print_color green "📊 删除了 $cleaned_count 个日志文件"
        print_color green "💾 释放了 $size_text 空间"
    else
        print_color yellow "📝 没有找到需要清理的日志文件"
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
LazyRun v${LAZYRUN_VERSION} - 后台任务管理器

用法: lazyrun [选项] <命令>

选项:
  --help, -h     显示帮助
  --version, -v  显示版本

子命令:
  lazylist       列出活跃任务
  lazylog        查看任务日志  
  lazykill       终止任务
  lazypush       测试推送功能
  lazyclean      清理日志

获取子命令帮助: <子命令> --help

示例:
  lazyrun python train.py    启动训练任务
  lazylist -f                实时监控
  lazylog train              查看日志
  lazykill train             终止任务
EOF
}

# 主函数
main() {
    # 检查参数
    if [ $# -eq 0 ]; then
        show_help
        return 1
    fi
    
    # 处理标准参数
    case "$1" in
        --help|-h)
            show_help
            return 0
            ;;
        --version|-v)
            echo "LazyRun v${LAZYRUN_VERSION} (构建于 ${LAZYRUN_BUILD_DATE})"
            return 0
            ;;
    esac
    
    # 运行命令 - 直接传递所有参数，无需引号
    local full_command=""
    for arg in "$@"; do
        if [ -z "$full_command" ]; then
            full_command="$arg"
        else
            full_command="$full_command $arg"
        fi
    done
    
    # 从完整命令中提取程序名作为任务名
    run_command_background "$full_command"
}

# 如果脚本被直接执行
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi

# 独立的短命令函数
lazylist() {
    list_active_jobs "$@"
}

lazylog() {
    # 新的合并函数，支持所有参数
    view_job_log "$@"
}

lazykill() {
    # 新的合并函数，支持-a参数
    kill_job "$@"
}

lazypush() {
    test_pushplus "$1"
}

lazyclean() {
    clean_logs "$1" "$2"
}
