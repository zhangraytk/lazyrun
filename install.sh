#!/bin/bash

# LazyRun 安装脚本
# 自动安装和配置 LazyRun 到系统中

set -e

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

# 检测 shell
detect_shell() {
    local shell_name
    
    # 首先检查用户的默认shell（最可靠的方法）
    if [ -n "$SHELL" ]; then
        shell_name=$(basename "$SHELL")
    # 然后检查当前运行的shell环境变量
    elif [ -n "$ZSH_VERSION" ]; then
        shell_name="zsh"
    elif [ -n "$BASH_VERSION" ]; then
        shell_name="bash"
    else
        # 最后尝试从进程名检测
        shell_name=$(ps -p $$ -o comm= 2>/dev/null | sed 's/^-//')
        [ -z "$shell_name" ] && shell_name="bash"  # 默认fallback
    fi
    
    echo "$shell_name"
}

# 获取配置文件路径
get_config_file() {
    local shell_name="$1"
    case "$shell_name" in
        zsh)
            if [ -f "$HOME/.zshrc" ]; then
                echo "$HOME/.zshrc"
            else
                echo "$HOME/.zshrc"
            fi
            ;;
        bash)
            if [ -f "$HOME/.bashrc" ]; then
                echo "$HOME/.bashrc"
            elif [ -f "$HOME/.bash_profile" ]; then
                echo "$HOME/.bash_profile"
            else
                echo "$HOME/.bashrc"
            fi
            ;;
        *)
            echo "$HOME/.profile"
            ;;
    esac
}

# 主安装函数
install_lazyrun() {
    local force_install="${1:-false}"
    
    if [ "$force_install" = "true" ]; then
        print_color blue "🔄 强制重装 LazyRun..."
    else
        print_color blue "🚀 开始安装 LazyRun..."
    fi
    
    # 检查当前目录是否包含必要文件
    if [ ! -f "./lazyrun.sh" ]; then
        print_color red "错误: 在当前目录中未找到 lazyrun.sh 文件"
        print_color yellow "请确保在包含 lazyrun.sh 的目录中运行此脚本"
        exit 1
    fi
    
    # 创建安装目录
    local install_dir="$HOME/.lazyrun"
    mkdir -p "$install_dir/bin"
    mkdir -p "$install_dir/logs"
    mkdir -p "$install_dir/pids"
    
    # 复制脚本文件
    print_color blue "📁 安装文件到 $install_dir/bin..."
    cp "./lazyrun.sh" "$install_dir/bin/"
    chmod +x "$install_dir/bin/lazyrun.sh"
    
    # 检测 shell 和配置文件
    local shell_name
    local config_file
    shell_name=$(detect_shell)
    config_file=$(get_config_file "$shell_name")
    
    print_color blue "🔧 检测到 shell: $shell_name"
    print_color blue "📝 配置文件: $config_file"
    
    # 检查是否已经安装
    if grep -q "# LazyRun Function" "$config_file" 2>/dev/null; then
        if [ "$force_install" = "true" ]; then
            print_color yellow "🔄 强制重装模式，直接覆盖现有配置..."
        else
            print_color yellow "⚠️  LazyRun 似乎已经安装，正在更新..."
        fi
        
        # 备份配置文件
        cp "$config_file" "${config_file}.lazyrun.backup.$(date +%Y%m%d_%H%M%S)"
        print_color green "✓ 配置文件已备份"
        
        # 移除旧的配置
        sed -i.tmp '/# LazyRun Function/,/# End of LazyRun/d' "$config_file"
        rm -f "${config_file}.tmp"
    elif [ "$force_install" = "true" ]; then
        print_color blue "🔄 强制重装模式，但未发现现有安装，执行全新安装..."
    fi
    
    # 添加函数到配置文件
    print_color blue "✏️  添加 lazyrun 函数到 $config_file..."
    
    cat >> "$config_file" << 'EOF'

# LazyRun Function
lazyrun() {
    local lazyrun_script="$HOME/.lazyrun/bin/lazyrun.sh"
    
    if [ ! -f "$lazyrun_script" ]; then
        echo "错误: LazyRun 脚本未找到: $lazyrun_script"
        echo "请重新运行安装脚本"
        return 1
    fi
    
    # 加载脚本中的所有函数
    source "$lazyrun_script"
    
    # 调用main函数运行命令
    main "$@"
}

# LazyRun 短命令函数
lazylist() {
    local lazyrun_script="$HOME/.lazyrun/bin/lazyrun.sh"
    source "$lazyrun_script"
    list_active_jobs
}

lazylogs() {
    local lazyrun_script="$HOME/.lazyrun/bin/lazyrun.sh"
    source "$lazyrun_script"
    list_all_logs
}

lazylog() {
    local lazyrun_script="$HOME/.lazyrun/bin/lazyrun.sh"
    source "$lazyrun_script"
    view_job_log "$@"
}

lazylogfol() {
    local lazyrun_script="$HOME/.lazyrun/bin/lazyrun.sh"
    source "$lazyrun_script"
    view_job_log "$1" follow
}

lazykill() {
    local lazyrun_script="$HOME/.lazyrun/bin/lazyrun.sh"
    source "$lazyrun_script"
    kill_job "$@"
}

lazykillall() {
    local lazyrun_script="$HOME/.lazyrun/bin/lazyrun.sh"
    source "$lazyrun_script"
    kill_all_jobs
}

lazyhelp() {
    local lazyrun_script="$HOME/.lazyrun/bin/lazyrun.sh"
    source "$lazyrun_script"
    show_help
}

lazypush() {
    local lazyrun_script="$HOME/.lazyrun/bin/lazyrun.sh"
    source "$lazyrun_script"
    test_pushplus "$1"
}

lazyclean() {
    local lazyrun_script="$HOME/.lazyrun/bin/lazyrun.sh"
    source "$lazyrun_script"
    clean_logs "$1" "$2"
}

# LazyRun 自动补全
_lazyrun_completion() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_WORDS_INDEX]}"
    prev="${COMP_WORDS[COMP_WORDS_INDEX-1]}"
    
    opts="--help --list --kill --kill-all --log --logs"
    
    if [[ ${cur} == --* ]] ; then
        COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
        return 0
    fi
    
    if [[ ${prev} == "--kill" ]] ; then
        local job_names
        if [ -f "$HOME/.lazyrun/pids/active_jobs" ]; then
            job_names=$(awk -F':' '{print $2}' "$HOME/.lazyrun/pids/active_jobs" 2>/dev/null)
            COMPREPLY=( $(compgen -W "${job_names}" -- ${cur}) )
        fi
        return 0
    fi
    
    if [[ ${prev} == "--log" ]] ; then
        local all_job_names
        if [ -d "$HOME/.lazyrun/logs" ]; then
            all_job_names=$(ls -1 "$HOME/.lazyrun/logs" 2>/dev/null | grep -v '\.log$')
            COMPREPLY=( $(compgen -W "${all_job_names}" -- ${cur}) )
        fi
        return 0
    fi
    
    if [ "${COMP_WORDS[COMP_WORDS_INDEX-2]}" = "--log" ]; then
        local log_modes="tail head cat follow"
        COMPREPLY=( $(compgen -W "${log_modes}" -- ${cur}) )
        return 0
    fi
}

# 注册自动补全
if [ -n "${BASH_VERSION}" ]; then
    complete -F _lazyrun_completion lazyrun
    complete -F _lazykill_completion lazykill
    complete -F _lazylog_completion lazylog
fi

# 短命令自动补全
_lazykill_completion() {
    local cur
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_WORDS_INDEX]}"
    
    local job_names
    if [ -f "$HOME/.lazyrun/pids/active_jobs" ]; then
        job_names=$(awk -F':' '{print $2}' "$HOME/.lazyrun/pids/active_jobs" 2>/dev/null)
        COMPREPLY=( $(compgen -W "${job_names}" -- ${cur}) )
    fi
}

_lazylog_completion() {
    local cur prev
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_WORDS_INDEX]}"
    prev="${COMP_WORDS[COMP_WORDS_INDEX-1]}"
    
    if [ ${COMP_WORDS_INDEX} -eq 1 ]; then
        # 第一个参数: 任务名补全
        local all_job_names
        if [ -d "$HOME/.lazyrun/logs" ]; then
            all_job_names=$(ls -1 "$HOME/.lazyrun/logs" 2>/dev/null | grep -v '\.log$')
            COMPREPLY=( $(compgen -W "${all_job_names}" -- ${cur}) )
        fi
    elif [ ${COMP_WORDS_INDEX} -eq 2 ]; then
        # 第二个参数: 日志模式补全
        local log_modes="tail head cat follow"
        COMPREPLY=( $(compgen -W "${log_modes}" -- ${cur}) )
    fi
}
# End of LazyRun

EOF
    
    # 创建符号链接（可选，用于全局访问）
    local bin_dir="/usr/local/bin"
    if [ -w "$bin_dir" ] && [ -d "$bin_dir" ]; then
        print_color blue "🔗 创建全局符号链接..."
        ln -sf "$install_dir/bin/lazyrun.sh" "$bin_dir/lazyrun"
        print_color green "✓ 全局命令 'lazyrun' 已可用"
    else
        print_color yellow "⚠️  无法创建全局符号链接（权限不足或目录不存在）"
        print_color yellow "   使用 'lazyrun' 函数代替全局命令"
    fi
    
    print_color green "🎉 LazyRun 安装完成!"
    
    if [ "$force_install" = "true" ]; then
        print_color green "✅ 强制重装成功完成!"
    fi
    
    print_color blue "📋 安装摘要:"
    echo "   - 安装目录: $install_dir"
    echo "   - 脚本位置: $install_dir/bin/lazyrun.sh"
    echo "   - 日志目录: $install_dir/logs"
    echo "   - PID目录: $install_dir/pids"
    echo "   - 配置文件: $config_file"
    
    print_color yellow "🔄 请运行以下命令重新加载配置:"
    print_color blue "   source $config_file"
    
    print_color yellow "🔑 配置 PushPlus 令牌 (可选):"
    print_color blue "   export PUSHPLUS_TOKEN=\"your_token_here\""
    print_color blue "   echo 'export PUSHPLUS_TOKEN=\"your_token_here\"' >> $config_file"
    
    print_color yellow "📚 使用帮助:"
    print_color blue "   lazyrun --help"
}

# 卸载函数
uninstall_lazyrun() {
    print_color yellow "🗑️  开始卸载 LazyRun..."
    
    local shell_name
    local config_file
    shell_name=$(detect_shell)
    config_file=$(get_config_file "$shell_name")
    
    # 终止所有任务
    if [ -f "$HOME/.lazyrun/bin/lazyrun.sh" ]; then
        print_color blue "🛑 终止所有活跃任务..."
        bash "$HOME/.lazyrun/bin/lazyrun.sh" --kill-all 2>/dev/null || true
    fi
    
    # 从配置文件中移除
    if [ -f "$config_file" ] && grep -q "# LazyRun Function" "$config_file"; then
        print_color blue "📝 从配置文件中移除函数..."
        cp "$config_file" "${config_file}.uninstall.backup.$(date +%Y%m%d_%H%M%S)"
        sed -i.tmp '/# LazyRun Function/,/# End of LazyRun/d' "$config_file"
        rm -f "${config_file}.tmp"
        print_color green "✓ 配置文件已清理"
    fi
    
    # 移除安装目录
    if [ -d "$HOME/.lazyrun" ]; then
        print_color blue "📁 移除安装目录..."
        rm -rf "$HOME/.lazyrun"
        print_color green "✓ 安装目录已移除"
    fi
    
    # 移除全局符号链接
    if [ -L "/usr/local/bin/lazyrun" ]; then
        print_color blue "🔗 移除全局符号链接..."
        sudo rm -f "/usr/local/bin/lazyrun" 2>/dev/null || rm -f "/usr/local/bin/lazyrun" 2>/dev/null || true
        print_color green "✓ 全局符号链接已移除"
    fi
    
    print_color green "🎉 LazyRun 卸载完成!"
    print_color yellow "🔄 请运行以下命令重新加载配置:"
    print_color blue "   source $config_file"
}

# 显示帮助
show_help() {
    cat << EOF
LazyRun 安装脚本

用法:
    ./install.sh                - 安装 LazyRun
    ./install.sh --force        - 强制重装 LazyRun (覆盖现有安装)
    ./install.sh --uninstall    - 卸载 LazyRun
    ./install.sh --help         - 显示此帮助信息

说明:
    此脚本会将 LazyRun 安装到您的系统中，包括:
    - 复制脚本文件到 ~/.lazyrun/bin/
    - 添加 lazyrun 函数到您的 shell 配置文件
    - 设置自动补全功能
    - 可选创建全局符号链接

安装后可用的命令:
    lazyrun <命令>               - 在后台运行指定命令
    lazylist                     - 列出所有活跃任务
    lazykill <任务名>            - 终止指定任务
    lazykillall                  - 终止所有任务
    lazylog <任务名> [模式]      - 查看任务日志
    lazylogfol <任务名>          - 实时跟踪任务日志
    lazylogs                     - 列出近7天的任务日志
    lazypush [token]             - 测试PushPlus推送功能
    lazyclean [天数] [任务名]    - 清理日志文件
    lazyhelp                     - 显示LazyRun帮助信息

选项说明:
    --force     强制重装模式，直接覆盖现有安装而不询问
    --uninstall 完全卸载 LazyRun 及其所有配置文件
    --help      显示此帮助信息

EOF
}

# 主函数
main() {
    case "${1:-}" in
        --force)
            install_lazyrun true
            ;;
        --uninstall)
            uninstall_lazyrun
            ;;
        --help|-h)
            show_help
            ;;
        "")
            install_lazyrun false
            ;;
        *)
            print_color red "错误: 未知参数 '$1'"
            show_help
            exit 1
            ;;
    esac
}

# 运行主函数
main "$@"
