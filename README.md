# 域名证书管理面板

一个基于Shell脚本的域名SSL证书管理工具，用于监控证书状态、执行手动和自动续期操作。

## 功能特性

- 🔍 **证书状态监控**: 自动扫描证书目录，实时显示证书到期状态
- 🔄 **手动续期**: 支持单个域名的手动续期操作
- ⚡ **自动续期**: 批量处理即将过期的证书
- 🎛️ **交互式界面**: 清晰的表格显示和颜色状态标识
- ⚙️ **灵活配置**: 支持自定义证书路径和续期脚本
- 📝 **完整日志**: 详细的操作日志和错误记录
- 🕐 **定时任务**: 支持cron定时自动续期

## 环境要求

- **操作系统**: Linux/macOS
- **Shell**: Bash 4.0+（推荐）或 Bash 3.2+（兼容模式）
- **依赖工具**:
  - Docker (用于certbot)
  - OpenSSL (用于证书解析)

### Ubuntu/Debian 兼容性说明

在某些Ubuntu环境中，可能会遇到第二次运行时程序退出的问题。这通常是由于Bash版本兼容性导致的。

**解决方案：**

1. **使用兼容模式**：
   ```bash
   SKIP_CONFIG_CHECK=true ./cert_manager.sh
   ```

2. **运行兼容性测试**：
   ```bash
   ./test_ubuntu_fix.sh
   ```

3. **升级Bash版本**（推荐）：
   
   ```bash
   sudo apt update
   sudo apt install bash
   ```

## 快速开始

### 1. 安装部署

```bash
# 克隆或下载项目文件
git clone <repository-url>
cd cert-ssl

# 赋予执行权限
chmod +x cert_manager.sh
chmod +x ca_update

# 创建必要目录
mkdir -p logs
```

### 2. 配置证书目录

确保证书按以下结构组织：

```
cert/
├── domain1.com/
│   ├── fullchain.pem  # 或 cert.pem, certificate.pem
│   └── privkey.pem
├── domain2.com/
│   ├── fullchain.pem
│   └── privkey.pem
└── ...
```

### 3. 运行程序

```bash
# 启动交互式面板
./cert_manager.sh

# 执行自动续期后退出
./cert_manager.sh --auto-renew

# 指定自定义证书目录
./cert_manager.sh --cert-dir /path/to/certs

# 查看帮助信息
./cert_manager.sh --help

# 跳过配置检查
SKIP_CONFIG_CHECK=true ./cert_manager.sh
```

## 使用说明

### 交互式操作

启动程序后，会显示证书状态表格：

```
=== 域名证书管理面板 ===

序号 域名                      到期时间     剩余天数 状态       自动续期 证书位置
----------------------------------------------------------------------------------------------------
1    example.com              2024-03-15   30       正常       是       example.com/fullchain.pem
2    test.com                 2024-02-20   5        即将过期   是       test.com/fullchain.pem

操作指令:
  s + [序号] - 手动续期指定域名
  a - 自动续期所有需要续期的域名
  r - 刷新显示
  t + [序号] - 切换自动续期开关
  h - 显示帮助
  q - 退出程序
```

### 状态说明

| 状态 | 描述 | 剩余天数 | 颜色 |
|------|------|----------|------|
| 正常 | 证书有效期充足 | > 7天 | 绿色 |
| 即将过期 | 证书即将到期 | 3-7天 | 黄色 |
| 警告 | 证书紧急状态 | 1-2天 | 红色 |
| 已过期 | 证书已过期 | ≤ 0天 | 红色 |

### 操作指令详解

- **`s1`**: 为序号1的域名执行手动续期
- **`a`**: 自动续期所有启用自动续期且状态为"即将过期"、"警告"或"已过期"的域名
- **`r`**: 重新扫描证书目录并刷新显示
- **`t1`**: 切换序号1域名的自动续期开关
- **`h`**: 显示详细帮助信息
- **`q`**: 退出程序

##### 配置文件

#### config.conf
主配置文件，包含以下配置项：
```bash
# 证书目录路径
CERT_DIR="./cert"

# 续期脚本路径
RENEW_SCRIPT="./ca_update"

# 日志目录路径
LOG_DIR="./logs"

# 自动续期配置文件路径
AUTO_RENEW_CONFIG="./auto_renew.conf"
```

#### auto_renew.conf (INI格式)
自动续期配置文件，采用INI格式，支持域名配置和全局设置：
```ini
# 域名证书自动续期配置文件 (INI格式)
# 配置每个域名的自动续期状态
# 格式: 域名 = 状态(true/false)

[auto_renew]
# 域名自动续期开关配置
example.com = true
test.example.com = false
api.example.com = true

[settings]
# 全局设置
default_auto_renew = true      # 新域名默认自动续期状态
renew_before_days = 7          # 续期前天数阈值
max_retry_count = 3            # 最大重试次数
```

**全局设置说明：**
- `default_auto_renew`: 新发现的域名默认是否启用自动续期
- `renew_before_days`: 证书到期前多少天开始续期（影响状态判断）
- `max_retry_count`: 续期失败时的最大重试次数

## 定时任务配置

### Cron定时任务示例

```bash
# 编辑crontab
crontab -e

# 添加以下行：每天凌晨2点执行自动续期检查
0 2 * * * /path/to/cert_manager.sh --auto-renew

# 或者每周日凌晨3点执行
0 3 * * 0 /path/to/cert_manager.sh --auto-renew
```

### Systemd服务配置

创建服务文件 `/etc/systemd/system/cert-auto-renew.service`：

```ini
[Unit]
Description=Certificate Auto Renewal
After=network.target

[Service]
Type=oneshot
User=root
WorkingDirectory=/path/to/cert-ssl
ExecStart=/path/to/cert-ssl/cert_manager.sh --auto-renew
```

创建定时器文件 `/etc/systemd/system/cert-auto-renew.timer`：

```ini
[Unit]
Description=Run certificate auto renewal daily
Requires=cert-auto-renew.service

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

启用服务：

```bash
sudo systemctl daemon-reload
sudo systemctl enable cert-auto-renew.timer
sudo systemctl start cert-auto-renew.timer

# 查看状态
sudo systemctl status cert-auto-renew.timer
```

## 日志管理

### 日志文件位置

- **主日志**: `logs/cert_manager.log`
- **续期日志**: `logs/renew_[域名]_[时间戳].log`

### 日志格式

```
[2024-01-15 10:30:45] INFO: 开始扫描证书目录: ./cert
[2024-01-15 10:30:46] INFO: 证书扫描完成，共发现 5 个有效证书
[2024-01-15 10:35:20] INFO: 开始续期域名: example.com
[2024-01-15 10:35:45] INFO: 域名 example.com 续期成功
```

## 故障排查

### 常见问题

1. **证书文件未找到**
   - 检查证书目录结构是否正确
   - 确认证书文件名是否为支持的格式（fullchain.pem, cert.pem等）

2. **续期脚本执行失败**
   - 检查ca_update脚本是否有执行权限
   - 确认Docker服务是否正常运行
   - 查看续期日志文件获取详细错误信息

3. **日期解析错误**
   - 在macOS上可能需要安装GNU date：`brew install coreutils`
   - 确认OpenSSL版本兼容性

4. **权限问题**
   - 确保脚本有读取证书文件的权限
   - 检查日志目录的写入权限

5. **配置文件损坏**

   **症状**：程序启动时报告配置文件格式错误

   **解决方案**：
   ```bash
   # 自动修复（推荐）
   ./cert_manager.sh  # 程序会自动检测并修复
   
   # 手动重置
   rm auto_renew.conf
   ./cert_manager.sh
   
   # 从示例文件恢复
   cp auto_renew.conf.example auto_renew.conf
   ```

### 调试模式

```bash
# 启用详细输出
bash -x ./cert_manager.sh

# 检查证书解析
openssl x509 -in cert/domain.com/fullchain.pem -noout -dates

# 测试续期脚本
./ca_update test domain.com
```

### 问题解决

1. **Ubuntu环境第二次运行退出**
   
   **症状**：首次运行正常，第二次运行直接退出
   
   **错误位置**：
   
   ```
   --- SCRIPT ERROR ---
   命令: '((line_count++))'
   在文件: './cert_manager.sh' 的第 1017 行
   以退出码 1 失败
   --------------------
   ```
   **原因**：当代码中加上`set +e`后，程序在检测到退出码为 **0**时自动退出
   
   >在 bash 里：
   >
   >- `(( ... ))` 不仅仅是自增运算，它还会根据运算结果返回一个 **退出状态码**（exit status）。
   >  - 如果结果是 **0**，退出码就是 **1（失败）**。
   >  - 如果结果是 **非 0**，退出码就是 **0（成功）**。
   >
   >再结合提到的：
   >
   >`((line_count++))`
   >
   >1. `line_count++` 是 **后缀自增**，返回的是 **自增前的值**。
   >2. 比如 `line_count=0` 时，`line_count++` 会返回 `0`（但 `line_count` 变成了 1）。
   >3. 返回值 `0` 会让 `((...))` 的退出码变成 **1**。
   >   - 如果你的脚本运行时开了 `set -e`（即遇到非零退出码就退出），那么脚本就直接退出了。
   >
   >可以改为`((++line_count))`
   >
   >1. `++line_count` 是 **前缀自增**，返回的是 **自增后的值**。
   >2. 比如 `line_count=0` 时，`++line_count` 会返回 `1`。
   >3. 返回值 `1` 让 `((...))` 的退出码变成 **0**，不会触发 `set -e` 退出。
   
   **解决方案：**
   
   - 去掉`set +e`
   - 将`((line_count++))`后自增改为`((++line_count))`前自增

## 安全注意事项

1. **文件权限**: 确保证书私钥文件权限设置为600
2. **日志安全**: 日志文件不记录敏感信息如私钥内容
3. **脚本权限**: 建议使用专用用户运行，避免使用root权限
4. **备份策略**: 定期备份证书文件和配置

## 扩展功能

本工具设计为模块化架构，可根据需要扩展以下功能：

- Web界面支持
- 邮件/短信告警通知
- 多服务器证书同步
- API接口支持
- 证书申请功能集成

## 许可证

本项目采用MIT许可证，详见LICENSE文件。

## 贡献

欢迎提交Issue和Pull Request来改进本项目。

## 联系方式

如有问题或建议，请通过以下方式联系：

- 提交Issue: [项目Issues页面]
- 邮件: [维护者邮箱]