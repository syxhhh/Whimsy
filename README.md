# Whimsy

在**空白 Windows** 上用一行命令跑起来的终端智能体。

不需要 Python、不需要 Node、不需要 git、不需要 API Key、不花钱。

> 当前版本 v1.2（2026-11-15）：对齐了 `D:\DSA` 里已经踩过坑的那几处——外部程序 stderr 不再被误判为失败、返回值带真实退出码、工具格式跑偏会自动要求重写、残留浏览器进程自动清理、跨任务带上下文。

## 一行启动

打开 PowerShell（Win + X → 终端），粘贴回车：

```powershell
curl.exe -sL https://raw.githubusercontent.com/syxhhh/Whimsy/main/ds.ps1 -o "$env:TEMP\w.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\w.ps1"
```

第一次运行会自动弹出浏览器，让你登录一次 DeepSeek（手机号或微信扫码）。**只需登录这一次**，之后每次都会记住。

看到 `你 >` 就可以派活了：

```
你 > 看看这台电脑的配置
你 > 在桌面新建一个 待办.txt，写上今天的三件事
你 > 把 D:\下载 里的图片按日期分类
```

## 先确认你的环境

```powershell
"PS $($PSVersionTable.PSVersion)  OS $([Environment]::OSVersion.Version)  curl $((Get-Command curl.exe -EA 0).Source)"
```

- 有 `curl` 路径 → 用上面的命令
- `curl` 为空（Win10 1803 以前）→ 用下面的 B 方案

**B. 没有 curl 的老系统**

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $f="$env:TEMP\w.ps1"; Invoke-WebRequest 'https://raw.githubusercontent.com/syxhhh/Whimsy/main/ds.ps1' -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f
```

## 它怎么工作

```
你的指令  →  DeepSeek 网页版（模型思考）
                ↓  输出 <tool>{"name":"run","command":"..."}</tool>
           本机 PowerShell 执行
                ↓  <result>结果</result> 回传
           继续循环，直到模型给出最终回答
```

技术上是用系统自带的 **Edge** 作为内核，通过 **CDP 协议**（Chrome DevTools Protocol）操作 `chat.deepseek.com` 网页版：

- 用 `Input.insertText` 往输入框注入文本（能正确触发 React 的 onChange）
- 轮询 DOM 拿流式回复，靠「文本停止变化」判定结束
- 全部逻辑用 PowerShell 的 `System.Net.WebSockets` 实现，**零第三方依赖**

没有用任何 API，所以没有 API Key，也没有费用。

## 它能做什么

四个工具：

| 工具 | 作用 |
|---|---|
| `run` | 执行任意 PowerShell 命令 |
| `read` | 读文件（自动识别 UTF-8 / GBK 编码） |
| `write` | 写文件（目录不存在会自动创建） |
| `ls` | 列目录 |

模型自己决定调哪个、调几次。实测：查硬件、写文件再读回来确认、多步任务串联，都能自己完成。

危险命令（删除、格式化、关机等）会先摆在你面前，需要按 `y` 确认。

## 实测数据

| 任务 | 耗时 |
|---|---|
| 简单问答 | 8 秒 |
| 列目录 | 11 秒 |
| 建文件 + 读回验证（2 步） | 15 秒 |
| 查 CPU 和内存 | 13 秒 |
| 读 GBK 编码的中文文件 | 10 秒 |
| 查 Java 环境（含 javac、JAVA_HOME、PATH 里真正生效的那个 java） | 11 秒 |

每一步约 5–8 秒，因为要走「网页版思考 + DOM 轮询」。这是免费换来的代价。

## 限制，先说清楚

- **比 API 版慢**：一步 5–8 秒，复杂任务要几十秒。如果你有 API Key，用下面的 API 版会快 3–5 倍。
- **依赖 DeepSeek 网页版的 DOM 结构**。DeepSeek 改版后可能失效，需要更新选择器（脚本里都集中在一处）。
- **运行时浏览器窗口不能关**。它可以缩到后台，但关掉就断了。
- **共用你的 DeepSeek 账号**。这不是 API Key，是你的登录态。给别人用等于共享账号，注意风险。
- **网页版没有原生的 function calling**，工具调用靠 `<tool>` 文本协议，模型偶尔会写歪（脚本做了容错解析）。

## 排查问题

只看浏览器和登录状态对不对，不进入对话：

```powershell
$env:WHIMSY_PROBE_ONLY='1'; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\w.ps1"
```

一次性执行任务再退出（适合脚本调用）：

```powershell
$env:WHIMSY_ONESHOT='看看内存占用'; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\w.ps1"
```

自定义配置目录（默认在 `%LOCALAPPDATA%\Whimsy`）：

```powershell
$env:WHIMSY_HOME='D:\myagent'
```

| 现象 | 原因 | 处理 |
|---|---|---|
| 卡在「浏览器没有响应」 | 上次的窗口没关，独占配置目录 | 关掉所有 Edge 窗口后重跑 |
| 一直停在「需要登录」 | 未登录 / 登录超时 | 在弹出窗口里完成登录 |
| 报「找不到 Edge 或 Chrome」 | 系统被精简过浏览器 | 装一个 Edge |
| 中文变成乱码 | 极少数终端的代码页异常 | 先执行 `chcp 936` |
| 命令明明成功了，却显示「执行失败：java : openjdk version…」 | v1.0 的 bug：`java -version`、`git`、`pip` 这类程序把结果写到 stderr，被误判成报错 | v1.1 已修复，重新下载脚本即可 |
| 执行完命令后没有任何输出，直接回到 `你 >` | v1.0 的 bug：模型这一轮没写总结时什么都不打印 | v1.1 已补上提示 |
| `Get-ChildItem | Format-Table` 被当成「格式化磁盘」要求确认 | v1.1 的危险规则 `\bformat\b` 误伤 `Format-Table` / `Format-List` | v1.2 已改为只匹配 `format 盘符:` |
| 模型输出一堆尖括号标签，直接糊在屏幕上 | v1.1 解析失败时把原始文本当答复打印 | v1.2 已改为要求模型重写一次 |

## 备选：API 版（更快，但需要 Key）

如果你有模型 API Key，`agent.ps1` 走标准 OpenAI 兼容接口，一步 1–3 秒：

```powershell
curl.exe -sL https://raw.githubusercontent.com/syxhhh/Whimsy/main/agent.ps1 -o "$env:TEMP\a.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\a.ps1"
```

启动前设置三个环境变量即可（以 DeepSeek 官方 API 为例）：

```powershell
$env:WHIMSY_KEY='sk-...'
$env:WHIMSY_BASE='https://api.deepseek.com/v1'
$env:WHIMSY_MODEL='deepseek-chat'
```

| | `ds.ps1`（网页版） | `agent.ps1`（API 版） |
|---|---|---|
| 费用 | 免费 | 按 token 计费 |
| 速度 | 5–8 秒/步 | 1–3 秒/步 |
| 需要 Key | 否 | 是 |
| 需要登录 | 是（一次） | 否 |
| 稳定性 | 看网页版 DOM | 看 API |

## 环境要求

**能跑：**

| 项 | 要求 |
|---|---|
| 系统 | Windows 10 1803 及以上 / Windows 11（x64、ARM64 都行） |
| 终端 | Windows PowerShell 5.1（系统自带，`powershell.exe`）；PowerShell 7 里也能跑，启动器会自动调 5.1 |
| 浏览器 | 系统自带 Edge，或已安装 Chrome |
| 网络 | 能打开 `chat.deepseek.com`；下载脚本时能访问 `raw.githubusercontent.com` |
| 账号 | 一个 DeepSeek 账号（免费） |

**跑不了：**

| 环境 | 原因 |
|---|---|
| Windows 7 / 8 / 8.1 | 没有 Chromium 版 Edge，也没有可用的调试协议 |
| macOS / Linux | 脚本用了 `%TEMP%`、`$env:LOCALAPPDATA`、Edge 路径，是纯 Windows 实现 |
| Windows Server Core / 精简版系统 | 没有浏览器，启动第一步就会失败 |
| 完全没有网络 | 网页版就是模型本体，断网等于没有大脑 |

**下载脚本这一步如果卡住**（`raw.githubusercontent.com` 在国内经常不通），换成 jsDelivr 镜像：

```powershell
curl.exe -sL https://cdn.jsdelivr.net/gh/syxhhh/Whimsy@main/ds.ps1 -o "$env:TEMP\w.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\w.ps1"
```

就这些。没有别的依赖。
