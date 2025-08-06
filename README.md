# LazyRun - 智能后台命令执行器

懒人的程序
为长时间任务设计的后台命令执行工具，支持智能任务管理、实时日志和推送通知。
通过nohup实现
copilot在调试修改中起到了重要的作用

## 已知的问题
zsh上可能有遇到精确匹配log失败的情况，简称匹配正常
管道符可能引发异常

## 🚀 安装

### 自动安装
```bash
cd lazyrun
./install.sh
```

### 手动安装
```bash
mkdir -p ~/.lazyrun/bin
cp lazyrun.sh ~/.lazyrun/bin/
chmod +x ~/.lazyrun/bin/lazyrun.sh
# 添加函数到 ~/.bashrc 或 ~/.zshrc (参考 install.sh)
```

## 📖 使用

### 基础命令
```bash
# 后台运行任务
lazyrun python train.py --epochs 100
lazyrun make clean && make && ./test

# 任务管理
lazylist                    # 查看活跃任务
lazykill python             # 终止任务 (支持简称)
lazykillall                 # 终止所有任务

# 日志查看
lazylog python              # 查看任务日志
lazylogfol python           # 实时跟踪日志
lazylogs                    # 所有任务统计

# 日志清理
lazyclean 7                 # 清理7天前日志
lazyclean 30 python         # 清理特定任务日志

# 推送测试
export PUSHPLUS_TOKEN="your_token"
lazypush                    # 测试推送功能
```

### 核心特性
- **无引号执行**: 直接传递复杂命令和管道
- **智能命名**: 程序名+时间戳，便于长期管理
- **智能匹配**: 简称匹配，自动选择最新任务
- **实时日志**: 支持跟踪正在运行的任务
- **自动通知**: 长任务(≥5分钟)自动推送完成通知

## 💡 示例

### 任务管理
```bash
# 查看运行中的任务
lazylist

# 终止python任务 (自动匹配最新的)
lazykill python

# 实时查看训练日志
lazylogfol python
```

### 日志管理
```bash
# 查看所有任务日志统计
lazylogs

# 清理旧日志释放空间
lazyclean 30

# 清理特定任务的旧日志
lazyclean 7 python
```

### 推送通知
```bash
# 设置推送token
export PUSHPLUS_TOKEN="your_pushplus_token"

# 测试推送功能
lazypush

# 长时间任务自动推送完成通知
lazyrun python long_training.py  # 运行≥5分钟自动推送
```

## �️ 文件结构
```
~/.lazyrun/
├── logs/           # 任务日志 (按任务名分目录)
├── pids/           # 进程追踪文件
└── bin/            # LazyRun脚本
```

## 🔧 卸载

```bash
# 使用安装脚本卸载
./install.sh --uninstall

# 手动卸载
rm -rf ~/.lazyrun
# 从 ~/.bashrc 或 ~/.zshrc 中删除 LazyRun 相关函数
```
