# vm-health-check
Virtual Machine Health Check Monitoring Scripts
# VM健康检查器

一个用于监控虚拟机健康状况的Bash脚本，支持详细解释模式和自动化监控。

## 功能特性

- ✅ CPU使用率监控
- ✅ 内存使用率监控
- ✅ 磁盘空间监控
- ✅ 彩色终端输出
- ✅ 详细解释模式 (`--explain`)
- ✅ 结构化输出（JSON格式）
- ✅ 日志记录功能
- ✅ 邮件告警支持
- ✅ 多平台兼容（Linux/Unix）

## 快速开始

### 安装

```bash
git clone https://github.com/17vision/vm-health-check
cd vm-health-check
chmod +x scripts/health_check.sh
```

### 使用

```
# 执行健康检查
./scripts/health_check.sh

# 显示详细解释
./scripts/health_check.sh --explain

# JSON格式输出
./scripts/health_check.sh --json
```

### 项目结构

vm-health-check/
├── scripts/
│   └── health_check.sh    # 主脚本
├── docs/
│   └── usage.md    # 使用文档
├── config/
│   └── thresholds.conf    # 阈值配置
└── logs/                  # 日志目录