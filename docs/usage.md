### 使用

```
# 执行健康检查
./scripts/health_check.sh

# 显示详细解释
./scripts/health_check.sh --explain

# 进入项目目录
cd vm-health-check

# 单次检查（日志自动生成在 logs/ 目录）
./scripts/health_check.sh

# 持续监控模式
./scripts/health_check.sh --monitor

# 指定监控间隔
./scripts/health_check.sh --monitor 30

# 限制监控次数
./scripts/health_check.sh --monitor 60 --max-checks 10

# 指定自定义配置文件
./scripts/health_check.sh --config config/my-thresholds.conf

# 指定自定义日志文件
./scripts/health_check.sh --log logs/custom.log
```