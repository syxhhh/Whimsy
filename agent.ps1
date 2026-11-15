#Requires -Version 5.1
<#
  Whimsy —— 单文件、零依赖的 Windows 终端智能体
  目标环境：全新 Windows 10/11，无需 Python / Node / git / 任何运行时

  一行运行：
    & ([scriptblock]::Create((irm https://cdn.jsdelivr.net/gh/syxhhh/Whimsy@main/agent.ps1)))
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { $OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ============ 配置 ============
$CFG = @{
    BaseUrl    = 'https://api.longcat.chat/openai/v1'
    Model      = 'LongCat-2.5'
    ApiKey     = 'ak_2Cg1HU7xm8mU39H7Sl1jb1oE2XI71'
    MaxTurns   = 40
    TimeoutSec = 120
    SafeMode   = $true
    MaxToolOut = 6000
    WorkDir    = (Get-Location).Path
}

# 环境变量可覆盖（换供应商 / 换 key 无需改文件）
if ($env:WHIMSY_KEY)   { $CFG.ApiKey  = $env:WHIMSY_KEY }
if ($env:WHIMSY_BASE)  { $CFG.BaseUrl = $env:WHIMSY_BASE }
if ($env:WHIMSY_MODEL) { $CFG.Model   = $env:WHIMSY_MODEL }

# ============ 输出 ============
function Read-Input {
    if ([Console]::IsInputRedirected) { return [Console]::In.ReadLine() }
    return (Read-Host)
}

function Say  { param($t, $c = 'Gray') Write-Host $t -ForegroundColor $c }
function Ok   { param($t) Write-Host "  [OK] $t" -ForegroundColor Green }
function Warn { param($t) Write-Host "  [!]  $t" -ForegroundColor Yellow }
function Bad  { param($t) Write-Host "  [x]  $t" -ForegroundColor Red }

# ============ JSON ============
# PowerShell 5.1 的 ConvertTo-Json 会把单元素数组压成对象，用 JavaScriptSerializer 规避
if (-not ('System.Web.Script.Serialization.JavaScriptSerializer' -as [type])) {
    Add-Type -AssemblyName System.Web.Extensions
}
$script:Ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:Ser.MaxJsonLength = 67108864
function To-JsonStr { param($o) $script:Ser.Serialize($o) }

# ============ HTTP ============
$script:Endpoint = "$($CFG.BaseUrl.TrimEnd('/'))/chat/completions"

function Invoke-Chat {
    param([object[]]$Messages, [int]$MaxTokens = 4096)

    $payload = @{
        model       = $CFG.Model
        messages    = $Messages
        max_tokens  = $MaxTokens
        temperature = 0.3
        stream      = $false
    }
    if ($script:Tools.Count -gt 0) { $payload['tools'] = $script:Tools }

    $body    = [Text.Encoding]::UTF8.GetBytes((To-JsonStr $payload))
    $headers = @{ Authorization = "Bearer $($CFG.ApiKey)"; Accept = 'application/json' }

    for ($i = 0; $i -lt 4; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri $script:Endpoint -Method Post -Headers $headers `
                    -ContentType 'application/json; charset=utf-8' `
                    -Body $body -TimeoutSec $CFG.TimeoutSec -UseBasicParsing
            $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
            return ($text | ConvertFrom-Json)
        }
        catch {
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode.value__ } catch {}
            if ($status -eq 401 -or $status -eq 403) {
                throw "鉴权失败（$status）：API Key 无效或没有权限"
            }
            if ($status -eq 402) {
                throw "额度不足（402）：这个 API Key 的免费额度已用完或未开通"
            }
            if ($status -eq 400) {
                throw "请求被拒（400）：$($_.Exception.Message) —— 可能是模型名不支持"
            }
            $retryable = ($status -eq 0 -or $status -eq 429 -or ($status -ge 500 -and $status -lt 600))
            if (-not $retryable -or $i -eq 3) { throw }
            Warn "请求失败（$status），$([math]::Pow(2,$i)) 秒后重试"
            Start-Sleep -Seconds ([math]::Pow(2, $i))
        }
    }
}

function Test-Endpoint {
    try {
        $null = Invoke-Chat -Messages @(@{ role = 'user'; content = 'ping' }) -MaxTokens 1
        return $true
    }
    catch { Bad $_.Exception.Message; return $false }
}

# ============ 工具实现 ============
$DANGEROUS = @(
    'Remove-Item', '\brm\b', '\bdel\b', '\brmdir\b', '\bformat\b',
    '\breg\s+delete\b', 'Stop-Computer', '\bshutdown\b', 'Clear-Disk',
    'Initialize-Disk', 'Remove-Partition', '\bmkfs\b', '\bdd\s+if='
)

function Test-Dangerous { param($c) foreach ($p in $DANGEROUS) { if ($c -match $p) { return $true } } return $false }

function Cut-Text {
    param($t, $max)
    if ($null -eq $t) { return '' }
    $t = [string]$t
    if ($t.Length -le $max) { return $t }
    return $t.Substring(0, $max) + "`n... [已截断，原长 $($t.Length) 字符]"
}

function Invoke-Tool {
    param($Name, $Param)

    switch ($Name) {

        'run_cmd' {
            $cmd = $Param['command']
            if (-not $cmd) { return '缺少 command 参数' }
            if ($CFG.SafeMode -and (Test-Dangerous $cmd)) {
                Say ''
                Warn '准备执行敏感命令：'
                Say "     $cmd" White
                $a = Read-Input
                if ($a -notmatch '^(y|Y|yes)$') { return '用户拒绝执行该命令。' }
            }
            Say "  > $cmd" DarkGray
            try {
                # 用当前宿主执行，不另起进程，保证环境一致
                $out = Invoke-Expression $cmd 2>&1 | Out-String
                return (Cut-Text $out $CFG.MaxToolOut)
            }
            catch { return "执行失败：$($_.Exception.Message)" }
        }

        'read_file' {
            $p = $Param['path']
            if (-not (Test-Path -LiteralPath $p)) { return "文件不存在：$p" }
            if (Test-Path -LiteralPath $p -PathType Container) { return "这是目录不是文件：$p" }
            try { return (Cut-Text (Get-Content -LiteralPath $p -Raw -Encoding UTF8) $CFG.MaxToolOut) }
            catch { return "读取失败：$($_.Exception.Message)" }
        }

        'write_file' {
            $p = $Param['path']
            $c = [string]$Param['content']
            try {
                $dir = Split-Path -Parent $p
                if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                }
                [IO.File]::WriteAllText($p, $c, (New-Object Text.UTF8Encoding($false)))
                return "已写入 $p（$($c.Length) 字符）"
            }
            catch { return "写入失败：$($_.Exception.Message)" }
        }

        'list_dir' {
            $p = if ($Param['path']) { $Param['path'] } else { '.' }
            if (-not (Test-Path -LiteralPath $p)) { return "目录不存在：$p" }
            try {
                $lines = Get-ChildItem -LiteralPath $p -Force | Select-Object -First 200 | ForEach-Object {
                    $t = if ($_.PSIsContainer) { '<DIR>     ' } else { '{0,10:N0}' -f $_.Length }
                    "$t  $($_.Name)"
                }
                return (Cut-Text ($lines -join "`n") $CFG.MaxToolOut)
            }
            catch { return "列目录失败：$($_.Exception.Message)" }
        }

        default { return "未知工具：$Name" }
    }
}

# ============ 工具声明 ============
$script:Tools = @(
    @{
        type     = 'function'
        function = @{
            name        = 'run_cmd'
            description = '在这台 Windows 电脑上执行一条 PowerShell 命令，返回输出。用于查看系统信息、运行程序、管理文件、安装软件。'
            parameters  = @{
                type       = 'object'
                properties = @{ command = @{ type = 'string'; description = '要执行的 PowerShell 命令，可多行用 ; 分隔' } }
                required   = @('command')
            }
        }
    },
    @{
        type     = 'function'
        function = @{
            name        = 'read_file'
            description = '读取一个文本文件的完整内容。'
            parameters  = @{
                type       = 'object'
                properties = @{ path = @{ type = 'string'; description = '文件路径（绝对或相对）' } }
                required   = @('path')
            }
        }
    },
    @{
        type     = 'function'
        function = @{
            name        = 'write_file'
            description = '把内容写入文件，覆盖原内容。目录不存在会自动创建。'
            parameters  = @{
                type       = 'object'
                properties = @{
                    path    = @{ type = 'string'; description = '文件路径' }
                    content = @{ type = 'string'; description = '要写入的完整内容' }
                }
                required   = @('path', 'content')
            }
        }
    },
    @{
        type     = 'function'
        function = @{
            name        = 'list_dir'
            description = '列出目录下的文件和子目录。'
            parameters  = @{
                type       = 'object'
                properties = @{ path = @{ type = 'string'; description = '目录路径，默认当前目录' } }
                required   = @()
            }
        }
    }
)

$SYS = @"
你是一个运行在 Windows 终端里的智能体，帮用户把事做完。

工作目录：$($CFG.WorkDir)
系统：Windows，默认终端是 PowerShell 5.1（不是 bash）

规则：
1. 需要操作电脑就直接调工具，不要只描述步骤。
2. 命令必须用 PowerShell 语法。没有 ls / rm / cat / grep / which，对应 Get-ChildItem / Remove-Item / Get-Content / Select-String / Get-Command。
3. 破坏性操作（删除、格式化、关机）先说明后果再执行。
4. 回答用中文，简洁，不要客套话和总结式废话。
5. 一次只做必要的调用，不要为了展示而堆砌。
"@

# ============ 主循环 ============
function Start-Agent {
    $history = @(@{ role = 'system'; content = $SYS })

    while ($true) {
        Write-Host ''
        Write-Host '你 > ' -ForegroundColor Cyan -NoNewline
        $line = Read-Input
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^(exit|quit|q|退出|再见)$') { break }

        $history += @{ role = 'user'; content = $line }
        $turn = 0

        while ($turn -lt $CFG.MaxTurns) {
            $turn++
            try {
                $r = Invoke-Chat -Messages $history
            }
            catch {
                Bad $_.Exception.Message
                break
            }

            if (-not $r.choices) { Bad '响应为空'; break }
            $m = $r.choices[0].message

            $content = if ($null -eq $m.content) { '' } else { [string]$m.content }
            $toolCalls = @($m.tool_calls | Where-Object { $null -ne $_ })

            $am = @{ role = 'assistant'; content = $content }
            if ($toolCalls.Count -gt 0) {
                $am['tool_calls'] = @($toolCalls | ForEach-Object {
                        @{
                            id       = $_.id
                            type     = 'function'
                            function = @{ name = $_.function.name; arguments = $_.function.arguments }
                        }
                    })
            }
            $history += $am

            if ($toolCalls.Count -eq 0) {
                if ($content) {
                    Say ''
                    Say $content White
                }
                break
            }

            foreach ($tc in $toolCalls) {
                $fname = $tc.function.name
                $params = @{}
                try {
                    $fa = $tc.function.arguments | ConvertFrom-Json
                    if ($fa) { foreach ($p in $fa.PSObject.Properties) { $params[$p.Name] = $p.Value } }
                }
                catch {}

                Say ''
                Say "  [$fname]" DarkCyan
                $result = Invoke-Tool -Name $fname -Param $params
                $preview = Cut-Text $result 400
                Say ("  " + ($preview -replace "`r?`n", "`n  ")) DarkGray

                $history += @{ role = 'tool'; tool_call_id = $tc.id; content = [string]$result }
            }
        }
    }
}

# ============ 启动 ============
Say ''
Say '  Whimsy' White
Say "  模型 $($CFG.Model)" DarkGray
Say "  目录 $($CFG.WorkDir)" DarkGray
Say ''

if (-not (Test-Endpoint)) {
    Say ''
    Bad '无法连接模型服务，退出。'
    Say '  检查：API Key 是否有效 / 额度是否用完 / 网络是否可达' DarkGray
    return
}

Ok '就绪'
Start-Agent
Say ''
Say '  再见。' DarkGray
