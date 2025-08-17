#!/bin/bash

# LazyRun 自动补全脚本
# 支持 bash 和 zsh

# 获取活跃任务列表
_lazyrun_get_active_tasks() {
    local active_file="${HOME}/.lazyrun/pids/active_jobs"
    if [ -f "$active_file" ]; then
        # 提取任务名称和程序简称
        awk -F':' '{
            # 完整任务名
            print $2
            # 程序简称（最后一个字段）
            if (NF >= 4) print $4
        }' "$active_file" 2>/dev/null | sort -u
    fi
}

# 获取日志中的任务名称
_lazyrun_get_log_tasks() {
    local log_dir="${HOME}/.lazyrun/logs"
    if [ -d "$log_dir" ]; then
        # 查找近期日志文件，提取程序名称
        find "$log_dir" -name "*.log" -mtime -30 2>/dev/null | while read -r log_file; do
            local filename=$(basename "$log_file")
            # 提取程序名称（去掉时间戳部分）
            echo "$filename" | sed -E 's/_[0-9]{8}_[0-9]{6}(_[0-9]+)?\.log$//'
        done | sort -u | head -20
    fi
}

# bash 自动补全
_lazyrun_completion_bash() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    
    # 根据不同的命令提供不同的补全
    case "${COMP_WORDS[0]}" in
        lazyrun)
            # lazyrun 命令补全文件名和命令
            COMPREPLY=($(compgen -f -- "$cur"))
            COMPREPLY+=($(compgen -c -- "$cur"))
            ;;
        lazykill)
            if [ "$cur" = "-a" ] || [ "$cur" = "--all" ] || [ "$cur" = "-h" ] || [ "$cur" = "--help" ]; then
                COMPREPLY=("-a" "--all" "-h" "--help")
            else
                # 补全活跃任务名称
                local tasks=$(_lazyrun_get_active_tasks)
                COMPREPLY=($(compgen -W "$tasks -a --all -h --help" -- "$cur"))
            fi
            ;;
        lazylog)
            case "$prev" in
                "-d"|"--day")
                    # -d/--day 参数后补全数字
                    COMPREPLY=($(compgen -W "1 3 7 14 30" -- "$cur"))
                    ;;
                *)
                    if [ "$cur" = "-d" ] || [ "$cur" = "--day" ] || [ "$cur" = "-h" ] || [ "$cur" = "--help" ]; then
                        COMPREPLY=("-d" "--day" "-h" "--help")
                    else
                        # 补全日志任务名称和动作
                        local log_tasks=$(_lazyrun_get_log_tasks)
                        local actions="tail cat follow -d --day -h --help"
                        COMPREPLY=($(compgen -W "$log_tasks $actions" -- "$cur"))
                    fi
                    ;;
            esac
            ;;
        lazylogfol)
            # 补全日志任务名称
            local log_tasks=$(_lazyrun_get_log_tasks)
            COMPREPLY=($(compgen -W "$log_tasks" -- "$cur"))
            ;;
        lazyclean)
            if [[ "$cur" =~ ^[0-9] ]]; then
                # 数字参数，不需要补全
                COMPREPLY=()
            elif [ "$cur" = "-h" ] || [ "$cur" = "--help" ]; then
                COMPREPLY=("-h" "--help")
            else
                # 补全任务名称和帮助参数
                local log_tasks=$(_lazyrun_get_log_tasks)
                COMPREPLY=($(compgen -W "$log_tasks -h --help" -- "$cur"))
            fi
            ;;
    esac
    
    return 0
}

# zsh 自动补全
_lazyrun_completion_zsh() {
    local state line
    typeset -A opt_args
    
    case "$service" in
        lazyrun)
            _alternative \
                'files:file:_files' \
                'commands:command:_command_names'
            ;;
        lazykill)
            local tasks=(${(f)"$(_lazyrun_get_active_tasks)"})
            _describe 'tasks' tasks
            _arguments \
                '-a[terminate all tasks]' \
                '--all[terminate all tasks]' \
                '-h[show help]' \
                '--help[show help]'
            ;;
        lazylog)
            _arguments \
                '-d[days]:days:(1 3 7 14 30)' \
                '--day[days]:days:(1 3 7 14 30)' \
                '-h[show help]' \
                '--help[show help]' \
                '*:task or action:(tail cat follow '$(_lazyrun_get_log_tasks)')'
            ;;
        lazylogfol)
            local log_tasks=(${(f)"$(_lazyrun_get_log_tasks)"})
            _describe 'log tasks' log_tasks
            ;;
        lazyclean)
            _arguments \
                '-h[show help]' \
                '--help[show help]' \
                '1:days:()' \
                '2:task:('$(_lazyrun_get_log_tasks)')'
            ;;
    esac
}

# 检测当前shell并注册自动补全
if [ -n "$BASH_VERSION" ]; then
    # Bash 补全
    complete -F _lazyrun_completion_bash lazyrun
    complete -F _lazyrun_completion_bash lazykill
    complete -F _lazyrun_completion_bash lazylog
    complete -F _lazyrun_completion_bash lazylogfol
    complete -F _lazyrun_completion_bash lazyclean
    complete -W "lazyrun lazylist lazykill lazylog lazylogs lazylogfol lazykillall lazyhelp lazypush lazyclean" lazyhelp
elif [ -n "$ZSH_VERSION" ]; then
    # Zsh 补全
    autoload -U compinit
    compinit
    
    compdef _lazyrun_completion_zsh lazyrun
    compdef _lazyrun_completion_zsh lazykill
    compdef _lazyrun_completion_zsh lazylog
    compdef _lazyrun_completion_zsh lazylogfol
    compdef _lazyrun_completion_zsh lazyclean
fi
