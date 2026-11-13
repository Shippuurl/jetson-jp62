# 串口日志：采集、筛选与本地打包

Windows PowerShell（需要 Python 3）：

```powershell
irm https://raw.githubusercontent.com/Shippuurl/jetson-jp62/main/uart-logs.ps1 | iex
```

国内网络取不到 GitHub 时，把上面地址的域名换成镜像：
`https://tool.kervein.club/jetson/uart-logs.ps1` / `https://tool.kervein.club/jetson/uart-logs.sh`。

Linux/macOS（需要 Python 3 与 venv）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Shippuurl/jetson-jp62/main/uart-logs.sh)
```

启动器自动建立独立 Python 环境并安装 pyserial 3.5。默认 115200、8N1、无流控，采集 60 秒；Ctrl-C 提前结束仍会打包。只读串口，不发送刷写命令。明确匹配一个 USB-TTL 时自动选择，多个端口交互选择；驱动需由操作系统正确安装。

Linux 原入口 `bash jetson-jp62.sh --mode uart` / 菜单 3 也接入此流程，保留原默认 30 秒。`--uart-out` 现为输出父目录，内部创建带时间戳的独立会话目录。

结果默认保存到 `~/Downloads/Jetson-Logs/时间戳/`：

- full.bin：原始字节，乱码也不丢。
- full.log：供人阅读的解码日志（去 ANSI 控制序列）。
- important.log：命中规则的行及上下文，标注原始行号。
- summary.json：状态、命中行、原始日志 SHA256。
- rules.json：此次使用的规则快照。
- all-logs.zip / important-logs.zip：全部 / 重要日志压缩包。
- index.html：本地快捷入口，点击下载两份压缩包。

日志不上传。规则是分板型的多个文件：`rules/index.json`（清单，含每个文件的 sha256 与版本）+ `common.json` / `jetson.json` / `raspberrypi.json`。

- 选择规则：`--board auto|common|jetson|raspberrypi`，默认 auto——先按 common 跑，日志里出现 `tegra/Jetson/Orin/L4T` 或 `Raspberry Pi/bcm27` 就自动切到对应集合。
- 固定版本：`--rules <目录或单文件>`，或 `SERIAL_LOG_RULES_DIR`，或用户配置目录（Windows `%APPDATA%\serial-log\rules`、macOS `Application Support`、Linux `~/.config/serial-log/rules`），最后才用内置目录。
- 更新：`--update-rules <url|目录>` 逐个文件校验 sha256（不一致直接中止、不会写一半）、拒绝版本回退（`--force` 放行）、旧目录整份备份、临时目录 + `os.replace` 原子替换。发布前用 `--make-index` 重新固定哈希。
- 哈希只防传输损坏；要防上游被改需要清单签名，这一步没做。

规则仅支持大小写不敏感的文字包含匹配，不执行代码或任意正则。修改 id、terms、context（0–30 行）、severity（error/warn/info）与 advice 即可维护。规则匹配并不等于确定故障；没有输出也不能判断固件损坏。

离线与回放：`--input <日志>`（别名 `--replay`）用新规则重跑旧日志；`--pack <会话目录>` 重新打包历史采集。

本地 Python 高级用法：`python uart-logs.py --port COM3 --seconds 120`；已有日志：`python uart-logs.py --input boot.log --offline`；`--seconds 0` 持续直到 Ctrl-C。

40-pin GPIO UART 与调试控制台并非在所有载板/BSP上相同。应核实具体载板及控制台配置；不能保证从普通 GPIO UART 取得 BootROM/MB1 日志。接线图为信号关系示意，并非主板实拍。USB-TTL 使用 3.3V 电平，VCC 不接，Jetson 独立供电。

验证：离线解析/上下文/原始字节保留/ZIP 成员单测通过；Windows 实机 COM 采集尚待验证。
