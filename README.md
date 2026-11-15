# Whimsy

Windows 终端里的 AI 智能体。**零依赖**——不需要 Python、不需要 Node、不需要 git，全新系统粘贴一行就能跑。

## 先看你的环境

在 PowerShell 里跑这一行，把结果发我（或自己对照下表）：

```powershell
"PS $($PSVersionTable.PSVersion)  OS $((Get-CimInstance Win32_OperatingSystem).Version)  curl $((Get-Command curl.exe -EA 0).Source)"
```

## 启动命令（按环境选）

### A. 通用版 —— Windows 10 1803+ / Windows 11（推荐）

PowerShell 或 CMD 都能用：

```powershell
curl.exe -sL https://raw.githubusercontent.com/syxhhh/Whimsy/main/agent.ps1 -o "$env:TEMP\whimsy.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\whimsy.ps1"
```

CMD 里把 `$env:TEMP` 换成 `%TEMP%`：

```cmd
curl.exe -sL https://raw.githubusercontent.com/syxhhh/Whimsy/main/agent.ps1 -o %TEMP%\whimsy.ps1 && powershell -NoProfile -ExecutionPolicy Bypass -File %TEMP%\whimsy.ps1
```

### B. 没有 curl 的老系统（Win7 / Win10 早期版本）

需要 PS 5.1 或更高。先设 TLS，再拉取：

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/syxhhh/Whimsy/main/agent.ps1').TrimStart([char]0xFEFF)))
```

### C. 想先看代码再跑（最安全）

```powershell
curl.exe -sL https://raw.githubusercontent.com/syxhhh/Whimsy/main/agent.ps1 -o "$env:USERPROFILE\Desktop\whimsy.ps1"
```

用记事本打开看过，确认没问题再：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Desktop\whimsy.ps1"
```

## 为什么 A 版要这么写

| 细节 | 原因 |
|---|---|
| 用 `curl.exe` 不用 `irm` | PS 5.1 默认 TLS 1.0，连 GitHub 直接握手失败。curl 走系统 schannel，没这问题 |
| 下载成文件执行 | 脚本含中文，PS 5.1 只认带 BOM 的 UTF-8。直接 `irm \| iex` 会把 BOM 塞进语法里导致报错 |
| `-ExecutionPolicy Bypass` | 绕过默认的 Restricted 策略，否则拒绝运行 |
| `-NoProfile` | 跳过用户自定义配置，避免环境干扰 |

## 它能做什么

四个工具，一个循环：

| 工具 | 作用 |
|---|---|
| `run_cmd` | 执行 PowerShell 命令 |
| `read_file` | 读文件 |
| `write_file` | 写文件 |
| `list_dir` | 列目录 |

模型自己决定调哪个、调几次，直到把事做完。

## 使用示例

```
你 > 帮我把桌面上的截图按日期整理到文件夹里
你 > 看看这个项目是什么语言写的
你 > 找一下昨天改过的文件
```

输入 `exit` 退出。

## 换模型

默认走 LongCat。要换供应商，设环境变量即可，不用改文件：

```powershell
$env:WHIMSY_KEY   = '你的key'
$env:WHIMSY_BASE  = 'https://api.deepseek.com/v1'
$env:WHIMSY_MODEL = 'deepseek-v4-flash'
```

任何 OpenAI 兼容接口都能用。

## 注意

- 危险命令（删除、格式化、关机）会先弹确认，输 `y` 才执行
- 脚本会在你的电脑上真实执行命令，理解代码再用
- 免费额度有限，别拿它跑批量任务

## 协议

MIT
