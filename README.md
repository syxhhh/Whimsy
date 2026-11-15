# Whimsy

Windows 终端里的 AI 智能体。**零依赖**——不需要 Python、不需要 Node、不需要 git，全新系统粘贴一行就能跑。

## 一行启动

打开 PowerShell（Win + X → 终端 / Windows PowerShell），粘贴：

```powershell
& ([scriptblock]::Create((irm https://cdn.jsdelivr.net/gh/syxhhh/Whimsy@main/agent.ps1)))
```

按回车。看到 `[OK] 就绪` 就可以开始对话了。

如果 jsDelivr 拉不动，换这个：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/syxhhh/Whimsy/main/agent.ps1)))
```

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

脚本默认走 LongCat。要换供应商，设环境变量即可，不用改文件：

```powershell
$env:WHIMSY_KEY   = '你的key'
$env:WHIMSY_BASE  = 'https://api.deepseek.com/v1'
$env:WHIMSY_MODEL = 'deepseek-v4-flash'
```

任何 OpenAI 兼容接口都能用。

## 注意

- 危险命令（删除、格式化、关机）会先弹确认，输 `y` 才执行
- 免费额度有限，别拿它跑批量任务
- 脚本会在你的电脑上真实执行命令，理解代码再用

## 协议

MIT
