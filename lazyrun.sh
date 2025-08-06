#!/bin/bash

# lazyrun - 智能后台任务管理器
# 作者: Ray, GitHub Copilot  
# 版本: 2.0
# 兼容: Linux, macOS
# 新特性: 三级目录结构，智能匹配，时间范围查询

# 配置变量
LAZYRUN_LOG_DIR="${HOME}/.lazyrun/logs"
LAZYRUN_PID_DIR="${HOME}/.lazyrun/pids"
PUSHPLUS_TOKEN="${PUSHPLUS_TOKEN:-}"  # 从环境变量获取，或手动设置
MIN_RUN_TIME=300  # 5分钟 = 300秒
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

# 生成任务简称
# 后台运行函数
run_command_background() {
    local cmd="$1"
    
    # 生成任务基础名称（程序简称）
    local base_name=$(echo "$cmd" | awk '{print $1}' | sed 's/[^a-zA-Z0-9_]/_/g')
    if [ -z "$base_name" ] || [ "$base_name" = "_" ]; then
        base_name="task"
    fi
    base_name=$(basename "$base_name")
    base_name="${base_name%.*}"
    
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
    nohup bash -c '
        # 设置陷阱处理信号
        trap "exit 130" INT
        trap "exit 143" TERM
        
        # 记录PID和任务信息
        echo $$ > "'"$pid_file"'"
        
        # 实时写入日志开始标记
        echo ">>> 命令开始执行: $(date \"+%Y-%m-%d %H:%M:%S\")" >> "'"$log_file"'"
        
        # 使用 eval 执行命令，实时写入日志
        if eval "'"$cmd"'" >> "'"$log_file"'" 2>&1; then
            exit_code=0
        else
            exit_code=$?
        fi
        
        end_time=$(date +%s)
        duration=$((end_time - '"$start_time"'))
        
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
        if [ "$end_year" != "'"$year"'" ] || [ "$end_month" != "'"$month"'" ] || [ "$end_day" != "'"$day"'" ]; then
            end_log_dir="'"$LAZYRUN_LOG_DIR"'/$end_year/$end_month/$end_day"
            mkdir -p "$end_log_dir"
            link_name="'"${final_log_name}"'_crossday.log"
            ln -sf "'"$log_file"'" "$end_log_dir/$link_name" 2>/dev/null
            echo ">>> 跨天运行检测: 在 $end_year/$end_month/$end_day 创建日志链接" >> "'"$log_file"'"
        fi
        
        # 实时写入完成信息
        {
            echo ""
            echo ">>> 命令执行完成: $(date \"+%Y-%m-%d %H:%M:%S\")"
            echo ">>> 运行时长: $duration_text"
            echo ">>> 退出代码: $exit_code"
            echo "================================================================================"
        } >> "'"$log_file"'"
        
        
        # 检查是否需要发送通知
        if [ $duration -ge '"$MIN_RUN_TIME"' ]; then
            if [ $exit_code -eq 0 ]; then
                status_text="✅ 成功完成"
            else
                status_text="❌ 执行失败 (退出码: $exit_code)"
            fi
            
            notification_title="LazyRun 任务完成: '"$final_log_name"'"
            notification_content="任务名称: '"$final_log_name"'
运行命令: '"$cmd"'
执行状态: $status_text
运行时长: $duration_text
完成时间: $(date \"+%Y-%m-%d %H:%M:%S\")
日志文件: '"$log_file"'"
            
            # 如果设置了PUSHPLUS_TOKEN，发送通知
            if [ -n "'"$PUSHPLUS_TOKEN"'" ]; then
                json_data="{\"token\": \"'"$PUSHPLUS_TOKEN"'\", \"title\": \"'"$PUSHTITLE"'\", \"content\": \"$notification_content\"}"
                curl -s -X POST -H "Content-Type: application/json" -d "$json_data" "http://www.pushplus.plus/send" > /dev/null 2>&1
                echo ">>> 推送通知已发送" >> "'"$log_file"'"
            fi
        else
            echo ">>> 任务运行时间少于5分钟，跳过推送通知" >> "'"$log_file"'"
        fi
        
        # 清理PID文件
        rm -f "'"$pid_file"'"
        
        exit $exit_code
    ' > /dev/null 2>&1 &
    
    local bg_pid=$!
    echo "🆔 后台进程PID: $bg_pid"
    echo "$bg_pid:$final_log_name:$start_time:$base_name" >> "$LAZYRUN_PID_DIR/active_jobs"
    echo ""
}

# 列出活跃任务
list_active_jobs() {
    local active_file="$LAZYRUN_PID_DIR/active_jobs"
    
    if [ ! -f "$active_file" ]; then
        print_color yellow "没有找到活跃的任务"
        return
    fi
    
    print_color blue "🔄 活跃的 LazyRun 任务:"
    printf "%-15s %-10s %-20s %-15s %-25s\n" "任务名称" "PID" "开始时间" "运行时长" "完整ID"
    echo "--------------------------------------------------------------------------------"
    
    # 清理已完成的任务
    local temp_file=$(mktemp)
    
    while IFS=':' read -r pid job_name start_time base_name; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            # 进程仍在运行
            local current_time=$(get_timestamp)
            local duration=$(calculate_duration $start_time $current_time)
            printf "%-15s %-10s %-20s %-15s %-25s\n" "$job_name" "$pid" "$(format_time $start_time)" "$duration" "$base_name"
            echo "$pid:$job_name:$start_time:$base_name" >> "$temp_file"
        fi
    done < "$active_file"
    
    mv "$temp_file" "$active_file"
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

# 新的智能日志匹配函数（用于lazylog）
smart_log_search() {
    local search_term="$1"
    local max_days="${2:-$DEFAULT_SEARCH_DAYS}"
    local is_full_name=false
    
    # 判断是否包含日期时间格式（支持部分匹配）
    if [[ "$search_term" =~ _[0-9]{8}(_[0-9]{1,6})?(_[0-9]+)?$ ]] || [[ "$search_term" =~ _[0-9]{4}[0-9]{2}[0-9]{2}_ ]]; then
        is_full_name=true
    fi
    
    if [ "$is_full_name" = true ]; then
        # 路径匹配模式：直接在目录结构中查找完整或部分文件名
        path_based_log_search "$search_term"
    else
        # 智能匹配模式：基于程序简称搜索
        intelligent_log_search "$search_term" "$max_days"
    fi
}

# 路径匹配搜索（用于完整日志名）
path_based_log_search() {
    local search_term="$1"
    local found_files=()
    
    # 从搜索词中提取日期信息（使用sed而不是正则表达式）
    local date_part=$(echo "$search_term" | grep -o '_[0-9]\{8\}' | head -1)
    if [ -n "$date_part" ]; then
        # 提取年月日
        local year=$(echo "$date_part" | cut -c2-5)
        local month=$(echo "$date_part" | cut -c6-7)
        local day=$(echo "$date_part" | cut -c8-9)
        
        local search_dir="$LAZYRUN_LOG_DIR/$year/$month/$day"
        
        if [ -d "$search_dir" ]; then
            # 在指定日期目录中查找匹配的文件
            local search_pattern="${search_dir}/${search_term}*.log"
            for file in $search_pattern; do
                if [ -f "$file" ]; then
                    found_files+=("$file")
                fi
            done
            
            # 如果没找到完全匹配，尝试部分匹配
            if [ ${#found_files[@]} -eq 0 ]; then
                for file in "$search_dir"/*.log; do
                    if [ -f "$file" ]; then
                        local basename_file=$(basename "$file" .log)
                        if [[ "$basename_file" == "${search_term}"* ]]; then
                            found_files+=("$file")
                        fi
                    fi
                done
            fi
        fi
    else
        # 如果搜索词不包含日期，在所有目录中查找
        for file in "$LAZYRUN_LOG_DIR"/*/*/*/*.log; do
            if [ -f "$file" ]; then
                local basename_file=$(basename "$file" .log)
                if [[ "$basename_file" == "${search_term}"* ]]; then
                    found_files+=("$file")
                fi
            fi
        done
    fi
    
    # 根据匹配结果处理
    case ${#found_files[@]} in
        0)
            return 1
            ;;
        1)
            echo "${found_files[0]}"
            return 0
            ;;
        *)
            # 多个匹配，显示选择菜单
            print_color yellow "找到 ${#found_files[@]} 个匹配的日志文件:" >&2
            print_color blue "请选择要查看的日志文件:" >&2
            
            local i=1
            for file in "${found_files[@]}"; do
                local file_name=$(basename "$file")
                local file_date=""
                # 从路径中提取日期
                file_date=$(echo "$file" | grep -o '/[0-9]\{4\}/[0-9]\{2\}/[0-9]\{2\}/' | tr -d '/' | sed 's/\(.*\)\(..\)\(..\)/\1-\2-\3/')
                printf "  %d) %s (%s)\n" "$i" "$file_name" "$file_date" >&2
                ((i++))
            done
            
            if [ -t 0 ] && [ -t 2 ]; then
                printf "请输入序号 (1-%d) 或 'q' 退出: " "${#found_files[@]}" >&2
                local choice
                read choice </dev/tty 2>/dev/null || choice="q"
                
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#found_files[@]}" ]; then
                    echo "${found_files[$((choice-1))]}"
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
                # 按修改时间排序，选择最新的
                local latest_file=$(ls -t "${found_files[@]}" 2>/dev/null | head -1)
                if [ -n "$latest_file" ]; then
                    echo "$latest_file"
                    return 0
                fi
            fi
            return 1
            ;;
    esac
}

# 智能匹配搜索（用于程序简称）
intelligent_log_search() {
    local base_name="$1"
    local max_days="$2"
    
    # 从今天开始向前搜索，找到即停止
    for ((i=0; i<max_days; i++)); do
        local year month day
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            year=$(date -v-${i}d +%Y)
            month=$(date -v-${i}d +%m)
            day=$(date -v-${i}d +%d)
        else
            # Linux
            year=$(date -d "$i days ago" +%Y)
            month=$(date -d "$i days ago" +%m)
            day=$(date -d "$i days ago" +%d)
        fi
        
        local search_dir="$LAZYRUN_LOG_DIR/$year/$month/$day"
        
        # 如果该日期目录存在，查找匹配的日志文件
        if [ -d "$search_dir" ]; then
            # 查找最新的匹配文件（按修改时间排序）
            local latest_file=$(ls -t "$search_dir"/${base_name}_*.log 2>/dev/null | head -1)
            
            if [ -n "$latest_file" ] && [ -f "$latest_file" ]; then
                echo "$latest_file"
                return 0
            fi
        fi
    done
    
    # 如果在默认天数内没找到，询问用户是否继续搜索
    if [ "$max_days" -eq "$DEFAULT_SEARCH_DAYS" ]; then
        print_color yellow "在最近 $DEFAULT_SEARCH_DAYS 天内未找到匹配的日志" >&2
        if [ -t 0 ] && [ -t 2 ]; then
            printf "是否继续搜索更久远的日志？(y/N): " >&2
            
            # 简单的兼容性read，避免复杂的参数
            local reply
            read reply </dev/tty 2>/dev/null || reply="n"
            
            case "$reply" in
                [Yy]|[Yy][Ee][Ss])
                    intelligent_log_search "$base_name" "$MAX_SEARCH_DAYS"
                    return $?
                    ;;
                *)
                    return 1
                    ;;
            esac
        else
            print_color yellow "非交互式环境，跳过更久远日志搜索" >&2
        fi
    fi
    
    return 1
}

# 终止任务
kill_job() {
    local target_job="$1"
    local active_file="$LAZYRUN_PID_DIR/active_jobs"
    local found=false
    
    if [ ! -f "$active_file" ]; then
        print_color red "没有找到活跃的任务"
        return 1
    fi
    
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

# 终止所有任务
kill_all_jobs() {
    local active_file="$LAZYRUN_PID_DIR/active_jobs"
    
    if [ ! -f "$active_file" ]; then
        print_color yellow "没有找到活跃的任务"
        return
    fi
    
    print_color yellow "正在终止所有 LazyRun 任务..."
    
    while IFS=':' read -r pid job_name start_time base_name; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            print_color blue "终止任务: $job_name (PID: $pid)"
            kill -TERM "$pid" 2>/dev/null
        fi
    done < "$active_file"
    
    # 等待优雅终止
    sleep 2
    
    # 强制终止仍在运行的进程
    while IFS=':' read -r pid job_name start_time base_name; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            print_color yellow "强制终止: $job_name (PID: $pid)"
            kill -KILL "$pid" 2>/dev/null
        fi
    done < "$active_file"
    
    # 清理文件
    rm -f "$active_file"
    rm -f "$LAZYRUN_PID_DIR"/*.pid
    
    print_color green "✓ 所有任务已终止"
}

view_job_log() {
    local job_name="$1"
    local action="${2:-tail}"  # tail, head, cat, follow
    
    if [ -z "$job_name" ]; then
        print_color red "错误: 请指定任务名称或日志文件名"
        echo "用法: lazylog <任务名称或日志文件名> [tail|head|cat|follow]"
        return 1
    fi
    
    # 使用新的智能匹配查找日志文件
    local log_file=$(smart_log_search "$job_name")
    
    if [ -z "$log_file" ] || [ ! -f "$log_file" ]; then
        print_color red "未找到匹配的日志文件: $job_name"
        return 1
    fi
    
    print_color blue "📖 查看日志文件: $(basename "$log_file")"
    print_color green "完整路径: $log_file"
    
    case "$action" in
        tail)
            print_color green "显示最后50行日志:"
            tail -50 "$log_file"
            ;;
        head)
            print_color green "显示前50行日志:"
            head -50 "$log_file"
            ;;
        cat)
            print_color green "显示完整日志:"
            cat "$log_file"
            ;;
        follow)
            print_color green "实时跟踪日志 (Ctrl+C 退出):"
            tail -f "$log_file"
            ;;
        *)
            print_color red "错误: 未知的日志查看模式 '$action'"
            print_color blue "支持的模式: tail, head, cat, follow"
            return 1
            ;;
    esac
}

# 列出近7天的任务日志
list_all_logs() {
    print_color blue "📚 近7天的任务日志:"
    
    if [ ! -d "$LAZYRUN_LOG_DIR" ]; then
        print_color yellow "日志目录不存在"
        return
    fi
    
    printf "%-12s %-25s %-15s %-25s\n" "日期" "任务名称" "日志文件数" "最新日志"
    echo "--------------------------------------------------------------------------------"
    
    local found_logs=false
    
    # 遍历近7天
    for i in {0..6}; do
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
        print_color yellow "近7天没有找到任何日志文件"
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
LazyRun - 智能后台命令执行器

用法:
    lazyrun <命令参数...>             - 在后台运行指定命令 (无需引号)
    
任务管理命令:
    lazylist                          - 列出所有活跃任务
    lazykill <任务名>                 - 终止指定任务
    lazykillall                       - 终止所有任务
    
日志查看命令:
    lazylog <任务名> [模式]           - 查看任务日志 (支持简称匹配)
    lazylogfol <任务名>               - 实时跟踪任务日志 (快捷方式)
    lazylogs                          - 列出近7天的任务日志信息
    lazyclean [天数] [任务名]         - 清理指定天数前的日志
    
其他命令:
    lazyhelp                          - 显示帮助信息
    lazypush [token]                  - 测试PushPlus推送功能

日志查看模式:
    tail     - 显示最后50行 (默认)
    head     - 显示前50行
    cat      - 显示完整日志
    follow   - 实时跟踪日志

环境变量:
    PUSHPLUS_TOKEN                    - PushPlus推送令牌

示例:
    # 后台运行任务 (支持复杂命令和管道)
    lazyrun python train.py --epochs 100
    lazyrun make clean && make && ./test
    lazyrun cat data.txt | grep "error" | sort
    
    # 任务管理
    lazylist                             # 查看活跃任务
    lazykill python                      # 终止任务 (支持简称，自动选择最新的)
    lazykillall                          # 终止所有任务
    
    # 日志查看 (支持简称匹配)
    lazylog python                       # 查看最后50行日志
    lazylog python cat                   # 查看完整日志
    lazylogfol python                    # 实时跟踪日志 (常用快捷方式)
    lazylogs                             # 查看近7天任务日志统计
    
    # 日志清理
    lazyclean 7                          # 清理7天前的所有日志
    lazyclean 30 python                  # 清理python任务30天前的日志
    lazyclean                            # 清理7天前的日志(默认)
    
    # 推送测试
    lazypush your_token_here             # 测试PushPlus推送功能
    export PUSHPLUS_TOKEN="your_token"   # 设置推送令牌
    lazypush                             # 使用环境变量测试推送

配置:
    日志目录: $LAZYRUN_LOG_DIR (按YYYY-MM-DD/task_name结构存储)
    PID目录:  $LAZYRUN_PID_DIR
    最短推送时间: ${MIN_RUN_TIME}秒 (5分钟)

EOF
}

# 主函数
main() {
    # 检查参数
    if [ $# -eq 0 ]; then
        show_help
        return 1
    fi
    
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
    list_active_jobs
}

lazylogs() {
    list_all_logs
}

lazylog() {
    if [ -z "$1" ]; then
        print_color red "错误: 请指定要查看的任务名"
        print_color blue "使用 'lazylogs' 查看所有任务日志"
        return 1
    fi
    view_job_log "$1" "$2"
}

lazykill() {
    if [ -z "$1" ]; then
        print_color red "错误: 请指定要终止的任务名或ID"
        print_color blue "使用 'lazylist' 查看活跃任务"
        return 1
    fi
    kill_job "$1"
}

lazykillall() {
    kill_all_jobs
}

lazyhelp() {
    show_help
}

lazylogfol() {
    if [ -z "$1" ]; then
        print_color red "错误: 请指定要查看的任务名"
        print_color blue "使用 'lazylogs' 查看所有任务日志"
        return 1
    fi
    view_job_log "$1" "follow"
}

lazypush() {
    test_pushplus "$1"
}

lazyclean() {
    clean_logs "$1" "$2"
}
