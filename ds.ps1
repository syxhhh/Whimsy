# Whimsy Web —— 零依赖终端智能体（DeepSeek 网页版驱动）
# 目标环境：全新 Windows 10/11，无 Python / Node / git / API Key
# 原理：启动系统自带 Edge 作为浏览器内核，用 CDP 协议驱动 chat.deepseek.com 网页版
#
# 一行启动：
#   curl.exe -sL https://raw.githubusercontent.com/syxhhh/Whimsy/main/ds.ps1 -o "$env:TEMP\w.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\w.ps1"

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
# 不要强制把控制台改成 UTF-8：中文 Windows 终端默认是 GBK(936)，
# 强设 UTF-8 反而会让所有中文变成「鐢?DeepSeek」这种乱码。
try { $OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ============================================================ 配置
$homeDir = Join-Path $env:LOCALAPPDATA 'Whimsy'
if ($env:WHIMSY_HOME) { $homeDir = $env:WHIMSY_HOME }

$CFG = @{
    Url         = 'https://chat.deepseek.com/'
    Home        = $homeDir
    MaxTurns    = 24
    PollMs      = 400
    SettleSec   = 1.5
    AskTimeout  = 300
    MaxToolOut  = 3500
    MaxInputLen = 12000
}
$SYS = @'
你是一个运行在 Windows 上的终端智能体，可以操作这台电脑完成实际任务。

【工具调用格式】
需要操作电脑时，输出且只输出一个工具调用块：
<tool>{"name":"run","command":"Get-ChildItem -Force"}</tool>

可用工具：
1. run   —— 执行 PowerShell 命令，参数 command
2. read  —— 读取文本文件，参数 path
3. write —— 写入文件（覆盖），参数 path 和 content
4. ls    —— 列出目录，参数 path

【规则】
- 一次只调用一个工具，等结果返回后再决定下一步。
- 工具结果会以 <result>…</result> 的形式发给你。
- 任务完成后直接用中文回答，不要再调用工具。
- 这台机器是 Windows PowerShell，没有 ls / cat / rm / grep，请用 Get-ChildItem / Get-Content / Remove-Item / Select-String。
- 每次 run 都是一个全新的独立进程：上一次的 cd 和变量不会保留。需要连续操作时写成一条命令，或全部用绝对路径。
- 读文本文件优先用 read 工具，不要用 Get-Content：PowerShell 5.1 默认按 GBK 解码，读 UTF-8 文件会满屏乱码。
- 不要输出多余的说明文字，先干活。
'@

# ============================================================ 输出
function N-Line { param($t, $c = 'Gray') Write-Host $t -ForegroundColor $c }
function N-Ok   { param($t) Write-Host "  [OK] $t" -ForegroundColor Green }
function N-Warn { param($t) Write-Host "  [..] $t" -ForegroundColor DarkYellow }
function N-Bad  { param($t) Write-Host "  [!!] $t" -ForegroundColor Red }
function N-Head { param($t) Write-Host $t -ForegroundColor Cyan }

function Show-Banner {
    Write-Host ''
    Write-Host '  W H I M S Y' -ForegroundColor Cyan
    Write-Host '  由 DeepSeek 网页版驱动的终端智能体 · 零依赖 · 零费用' -ForegroundColor DarkGray
    Write-Host ''
}

# ============================================================ 浏览器定位
function Get-BrowserPath {
    $cands = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    foreach ($k in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
    )) {
        try {
            $p = (Get-ItemProperty -Path $k -ErrorAction Stop).'(default)'
            if ($p -and (Test-Path -LiteralPath $p)) { return $p }
        } catch {}
    }
    return $null
}

function Get-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start()
    $p = $l.LocalEndpoint.Port
    $l.Stop()
    return $p
}

# ============================================================ CDP 客户端
$script:WS     = $null
$script:MsgId  = 0
$script:Buf    = New-Object byte[] 1048576
$script:Seg    = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$script:Buf)
$script:CT     = [System.Threading.CancellationToken]::None

function Connect-Cdp {
    param([string]$WsUrl)
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.ConnectAsync([Uri]$WsUrl, $script:CT).Wait(15000) | Out-Null
    if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        throw '无法连接到浏览器调试端口'
    }
    $script:WS = $ws
    $script:MsgId = 0
}

function Close-Cdp {
    if ($script:WS) {
        try { $script:WS.Dispose() } catch {}
        $script:WS = $null
    }
}

function Invoke-Cdp {
    param([string]$Method, [hashtable]$Params, [int]$TimeoutMs = 45000)

    if (-not $script:WS) { throw '浏览器连接已断开' }

    $script:MsgId++
    $id = $script:MsgId
    $payload = @{ id = $id; method = $Method }
    if ($Params) { $payload['params'] = $Params }

    $json  = ConvertTo-Json $payload -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $eseg  = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$bytes)
    $script:WS.SendAsync($eseg, [Net.WebSockets.WebSocketMessageType]::Text, $true, $script:CT).Wait(15000) | Out-Null

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $sb = New-Object Text.StringBuilder

    while ($true) {
        $remain = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($remain -le 0) { throw "等待浏览器响应超时（$Method）" }

        $sb.Clear()
        $done = $false
        while (-not $done) {
            $task = $script:WS.ReceiveAsync($script:Seg, $script:CT)
            if (-not $task.Wait($remain)) { throw "接收浏览器数据超时（$Method）" }
            $res = $task.Result
            if ($res.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                throw '浏览器窗口已关闭'
            }
            if ($res.Count -gt 0) {
                $sb.Append([Text.Encoding]::UTF8.GetString($script:Buf, 0, $res.Count)) | Out-Null
            }
            $done = $res.EndOfMessage
        }

        $text = $sb.ToString()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $obj = $null
        try { $obj = $text | ConvertFrom-Json } catch { continue }
        if ($null -eq $obj) { continue }
        if ($obj.PSObject.Properties['id'] -and $obj.id -eq $id) { return $obj }
        # 其余是事件推送，丢弃
    }
}

function Invoke-Js {
    param([string]$Code, [int]$TimeoutMs = 45000)
    $r = Invoke-Cdp -Method 'Runtime.evaluate' -Params @{
        expression    = $Code
        returnByValue = $true
        awaitPromise  = $true
    } -TimeoutMs $TimeoutMs

    if ($r.PSObject.Properties['error'] -and $r.error) {
        throw "页面脚本出错：$($r.error.message)"
    }
    if ($r.result.PSObject.Properties['exceptionDetails'] -and $r.result.exceptionDetails) {
        throw "页面脚本异常：$($r.result.exceptionDetails.text)"
    }
    $v = $r.result.result.value
    if ($null -eq $v) { return '' }
    return [string]$v
}

# ============================================================ 页面探测
$JS_PROBE = @'
(() => {
  const ta = document.querySelector('textarea');
  return JSON.stringify({
    url: location.href,
    hasInput: !!ta,
    signed: !!ta && location.href.indexOf('sign_in') < 0,
    title: document.title
  });
})()
'@

$JS_SNAP = @'
(() => {
  const sels = [
    '.ds-markdown.ds-assistant-message-main-content',
    '.ds-markdown',
    'div[class*="ds-markdown"]'
  ];
  let nodes = [];
  for (const s of sels) {
    const n = document.querySelectorAll(s);
    if (n.length) { nodes = Array.prototype.slice.call(n); break; }
  }
  const texts = nodes.map(e => (e.innerText || '').trim()).filter(t => t);
  let busy = false;
  const stopSels = ['div[role="button"][aria-label*="停止"]', 'div[role="button"][aria-label*="Stop"]'];
  for (const s of stopSels) {
    if (document.querySelector(s)) { busy = true; break; }
  }
  return JSON.stringify({
    count: nodes.length,
    nonEmpty: texts.length,
    busy: busy,
    last: texts.length ? texts[texts.length - 1] : ''
  });
})()
'@

$JS_QUIET = @'
(() => {
  // 关掉「深度思考」和「智能搜索」，否则每轮都要多等几十秒且污染上下文
  const btns = Array.prototype.slice.call(document.querySelectorAll('div.ds-toggle-button'));
  let changed = 0;
  for (const b of btns) {
    const t = (b.innerText || '').trim();
    if (t.indexOf('深度思考') >= 0 || t.indexOf('智能搜索') >= 0) {
      if (b.getAttribute('aria-pressed') === 'true') { b.click(); changed++; }
    }
  }
  return String(changed);
})()
'@

function Get-Snapshot {
    $raw = Invoke-Js $JS_SNAP
    try { return ($raw | ConvertFrom-Json) }
    catch { return [pscustomobject]@{ count = 0; nonEmpty = 0; busy = $false; last = '' } }
}

# ============================================================ 发送消息
function Invoke-Submit {
    param([string]$Text)

    $focus = @'
(() => {
  const t = document.querySelector('textarea');
  if (!t) return '0';
  t.focus();
  const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
  setter.call(t, '');
  t.dispatchEvent(new Event('input', { bubbles: true }));
  return '1';
})()
'@
    $ok = Invoke-Js $focus
    if ($ok -ne '1') { throw '找不到输入框，页面可能还没加载好' }

    Start-Sleep -Milliseconds 120

    # 浏览器级文本输入，会正确触发 React 的 onChange
    Invoke-Cdp -Method 'Input.insertText' -Params @{ text = $Text } | Out-Null
    Start-Sleep -Milliseconds 250

    $click = @'
(() => {
  const cands = [
    'div[role="button"].ds-button--primary.ds-button--circle',
    'div[role="button"].ds-button--filled.ds-button--circle',
    'div[role="button"][class*="ds-button--circle"]'
  ];
  for (const s of cands) {
    const els = Array.prototype.slice.call(document.querySelectorAll(s)).filter(e => e.offsetParent !== null);
    for (const e of els) {
      const cls = String(e.className || '');
      if (cls.indexOf('disabled') >= 0) continue;
      e.click();
      return 'click';
    }
  }
  return 'none';
})()
'@
    $how = Invoke-Js $click

    if ($how -ne 'click') {
        # 兜底：模拟回车
        Invoke-Cdp -Method 'Input.dispatchKeyEvent' -Params @{
            type = 'keyDown'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13
        } | Out-Null
        Invoke-Cdp -Method 'Input.dispatchKeyEvent' -Params @{
            type = 'keyUp'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13
        } | Out-Null
    }
}

function Wait-Reply {
    param($Base, [int]$TimeoutSec = 0)

    if ($TimeoutSec -le 0) { $TimeoutSec = $CFG.AskTimeout }
    $t0 = Get-Date
    $last = ''
    $stableSince = $null
    $started = $false

    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
        try { $s = Get-Snapshot } catch { throw }

        $cur      = [string]$s.last
        $isNew    = $cur.Length -gt 0 -and ($s.count -gt $Base.count -or $cur -ne [string]$Base.last)

        if ($isNew) {
            if (-not $started) { $started = $true }
            if ($cur -ne $last) {
                $last = $cur
                $stableSince = Get-Date
            }
            elseif (-not $s.busy) {
                if (((Get-Date) - $stableSince).TotalSeconds -ge $CFG.SettleSec) { return $cur }
            }
        }
        Start-Sleep -Milliseconds $CFG.PollMs
    }

    if ($last.Length -gt 0) { return $last }
    throw '等待页面回复超时'
}

function Invoke-Ask {
    param([string]$Text)
    $base = Get-Snapshot
    Invoke-Submit $Text
    return (Wait-Reply -Base $base)
}

# ============================================================ 工具
$DANGER = @(
    '\bRemove-Item\b.*-Recurse', '\bformat\b', '\bdiskpart\b', '\bClear-Disk\b',
    '\bInitialize-Disk\b', '\bRemove-Partition\b', '\breg\s+delete\b',
    '\bStop-Computer\b', '\bRestart-Computer\b', '\bshutdown\b',
    'Remove-Item\s+[A-Za-z]:\\?\s*$', 'rd\s+/s\s+/q\s+[A-Za-z]:'
)

function Test-Danger {
    param([string]$Text)
    foreach ($p in $DANGER) { if ($Text -match $p) { return $true } }
    return $false
}

function Cut-Text {
    param([string]$Text, [int]$Max)
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + "`n…（已截断，原文 $($Text.Length) 字符）"
}

function Invoke-ShellText {
    param([string]$Command)

    # 外部程序（java -version、git、pip、npm…）把结果写到 stderr 是正常行为。
    # 如果直接 & powershell -Command 再 2>&1，PowerShell 会把它包装成 ErrorRecord；
    # 而本脚本全局是 $ErrorActionPreference='Stop'，于是「命令明明成功、只是输出走了 stderr」
    # 会被误判成「执行失败」。这里的做法是把命令写进临时脚本，在子进程内就把
    # ErrorRecord 还原成纯文本再输出到 stdout，父进程拿到的就永远是干净文本。
    $tmp = Join-Path $env:TEMP ('whimsy_run_' + [guid]::NewGuid().ToString('N') + '.ps1')
    $body = @"
`$ProgressPreference = 'SilentlyContinue'
try {
    & {
$Command
    } 2>&1 | ForEach-Object {
        if (`$_ -is [System.Management.Automation.ErrorRecord]) { `$_.Exception.Message } else { `$_ }
    } | Out-String -Width 300
}
catch {
    "执行出错：`$(`$_.Exception.Message)"
}
"@
    [IO.File]::WriteAllText($tmp, $body, (New-Object Text.UTF8Encoding($true)))
    try {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $tmp 2>&1 | Out-String
        $ErrorActionPreference = $prev
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    return $out
}

function Invoke-Tool {
    param($Call)

    $name = [string]$Call.name
    if (-not $name) { return '工具调用缺少 name 字段' }

    switch ($name) {

        'run' {
            $c = [string]$Call.command
            if (-not $c) { return '缺少 command 参数' }

            if (Test-Danger $c) {
                Write-Host ''
                N-Warn '这条命令可能删除数据，需要你确认：'
                Write-Host "      $c" -ForegroundColor White
                $a = Read-Host '      执行吗？(y/N)'
                if ($a -notmatch '^(y|Y|yes|YES)$') { return '用户拒绝执行这条命令，请换一种方式。' }
            }

            try {
                $out = (Invoke-ShellText $c).Trim()
                if ([string]::IsNullOrWhiteSpace($out)) { return '(命令执行完成，没有输出)' }
                return (Cut-Text $out $CFG.MaxToolOut)
            }
            catch { return "执行失败：$($_.Exception.Message)" }
        }

        'read' {
            $p = [string]$Call.path
            if (-not $p) { return '缺少 path 参数' }
            if (-not (Test-Path -LiteralPath $p)) { return "文件不存在：$p" }

            try {
                $fi = Get-Item -LiteralPath $p
                if ($fi.PSIsContainer) { return "$p 是目录，用 ls 工具查看" }
                if ($fi.Length -gt 4MB) {
                    return "文件太大（$([math]::Round($fi.Length / 1MB, 1)) MB），请用命令只读取其中一部分"
                }

                $bytes = [IO.File]::ReadAllBytes($p)
                $text = $null
                # 先按「严格 UTF-8」解码；不是合法 UTF-8 再退回 GBK。
                # 这样自己写的文件和老式 ANSI 中文文件都能正确显示，
                # 避免 PowerShell 5.1 默认按 GBK 读 UTF-8 导致的一片乱码。
                try {
                    $strict = New-Object Text.UTF8Encoding($false, $true)
                    $text = $strict.GetString($bytes)
                }
                catch {
                    $text = [Text.Encoding]::GetEncoding(936).GetString($bytes)
                }
                if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
                return (Cut-Text $text $CFG.MaxToolOut)
            }
            catch { return "读取失败：$($_.Exception.Message)" }
        }

        'write' {
            $p = [string]$Call.path
            $c = [string]$Call.content
            if (-not $p) { return '缺少 path 参数' }
            try {
                $dir = Split-Path -Parent $p
                if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                }
                $enc = New-Object Text.UTF8Encoding($false)
                [IO.File]::WriteAllText($p, $c, $enc)
                return "已写入 $p（$($c.Length) 字符）"
            }
            catch { return "写入失败：$($_.Exception.Message)" }
        }

        'ls' {
            $p = [string]$Call.path
            if (-not $p) { $p = '.' }
            if (-not (Test-Path -LiteralPath $p)) { return "目录不存在：$p" }
            try {
                $items = Get-ChildItem -LiteralPath $p -Force | Select-Object -First 150
                if (-not $items) { return '(空目录)' }
                $lines = $items | ForEach-Object {
                    $mark = if ($_.PSIsContainer) { '<DIR>     ' } else { '{0,10:N0}' -f $_.Length }
                    "$mark  $($_.Name)"
                }
                return (Cut-Text ($lines -join "`n") $CFG.MaxToolOut)
            }
            catch { return "列目录失败：$($_.Exception.Message)" }
        }

        default { return "未知工具：$name" }
    }
}

# ============================================================ 解析工具调用
function Get-ToolCall {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $m = [regex]::Match($Text, '(?s)<tool>\s*(\{.*?\})\s*</tool>')
    if (-not $m.Success) {
        # 容错：模型可能漏了闭合标签
        $m2 = [regex]::Match($Text, '(?s)<tool>\s*(\{.*\})\s*$')
        if (-not $m2.Success) { return $null }
        $m = $m2
    }

    $json = $m.Groups[1].Value.Trim()
    try { return ($json | ConvertFrom-Json) } catch {}

    # 容错：末尾多余的逗号
    $fixed = $json -replace ',\s*}', '}'
    try { return ($fixed | ConvertFrom-Json) } catch {}

    return $null
}

function Get-CleanReply {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = [regex]::Replace($Text, '(?s)<tool>\s*\{.*?\}\s*(</tool>)?', '')
    return $t.Trim()
}

# ============================================================ 启动浏览器
function Start-Browser {
    $exe = Get-BrowserPath
    if (-not $exe) {
        N-Bad '找不到 Edge 或 Chrome'
        N-Line '  这台机器可能被精简过浏览器。请手动安装 Edge：https://www.microsoft.com/edge' 'White'
        throw '缺少浏览器'
    }

    $profDir = Join-Path $CFG.Home 'profile'
    if (-not (Test-Path -LiteralPath $profDir)) {
        New-Item -ItemType Directory -Path $profDir -Force | Out-Null
    }

    $port = Get-FreePort
    $script:Port = $port

    $la = @(
        "--remote-debugging-port=$port",
        "--user-data-dir=$profDir",
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-sync',
        '--disable-background-timer-throttling',
        '--disable-backgrounding-occluded-windows',
        '--disable-renderer-backgrounding',
        '--disable-features=CalculateNativeWinOcclusion',
        '--window-size=1080,820',
        $CFG.Url
    )

    $script:BrowserProc = Start-Process -FilePath $exe -ArgumentList $la -PassThru
    N-Ok "浏览器  $(Split-Path -Leaf $exe) · 调试端口 $port"
    N-Ok "配置目录  $profDir"

    # 等调试端口就绪
    $list = $null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $list = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 4
            if ($list) { break }
        } catch {}
    }
    if (-not $list) {
        N-Bad '浏览器没有响应'
        N-Line '  多半是上一次的窗口没关，独占着配置目录。' 'White'
        N-Line "  请先关掉所有 Edge 窗口，或在任务管理器结束 msedge.exe 后重试。" 'White'
        throw '浏览器启动失败'
    }

    $page = $null
    for ($i = 0; $i -lt 12; $i++) {
        $page = $list | Where-Object { $_.type -eq 'page' -and $_.url -like '*deepseek*' } | Select-Object -First 1
        if (-not $page) { $page = $list | Where-Object { $_.type -eq 'page' } | Select-Object -First 1 }
        if ($page) { break }
        Start-Sleep -Milliseconds 400
        try { $list = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 4 } catch {}
    }
    if (-not $page) { throw '浏览器里没有可用页面' }

    Connect-Cdp -WsUrl $page.webSocketDebuggerUrl
    N-Ok '已接入浏览器'

    # 启动参数里的地址不一定已经加载完成（新配置初次启动时常常先停在 about:blank）。
    # 这里等到确实落在 DeepSeek 上；等不到就主动导航一次，避免后面误判成「未登录」。
    $landed = $false
    for ($i = 0; $i -lt 12; $i++) {
        try {
            $probe = (Invoke-Js $JS_PROBE) | ConvertFrom-Json
            if ($probe.url -like '*deepseek*') { $landed = $true; break }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    if (-not $landed) {
        try { Invoke-Cdp -Method 'Page.navigate' -Params @{ url = $CFG.Url } | Out-Null } catch {}
        Start-Sleep -Milliseconds 2200
    }
}

function Wait-SignedIn {
    $t0 = Get-Date
    $notified = $false
    while ($true) {
        $elapsed = [int]((Get-Date) - $t0).TotalSeconds
        try {
            $raw = Invoke-Js $JS_PROBE
            $p = $raw | ConvertFrom-Json
        }
        catch {
            # 页面正在导航/重载时会短暂取不到上下文，属正常，继续等
            Start-Sleep -Seconds 1
            continue
        }

        if ($p.signed) {
            Start-Sleep -Milliseconds 600
            try { Invoke-Js $JS_QUIET | Out-Null } catch {}
            return $true
        }

        # 只有确定停在登录页才提示，避免页面还在加载就吓唬人
        if (-not $notified -and $p.url -like '*sign_in*') {
            Write-Host ''
            N-Warn '需要登录一次（只需这一次，之后会记住）'
            Write-Host '      请在弹出的浏览器窗口里用手机号或微信扫码登录 DeepSeek' -ForegroundColor White
            Write-Host '      登录完成后这里会自动继续，不用回车' -ForegroundColor DarkGray
            Write-Host ''
            $notified = $true
        }

        if ($elapsed -gt 0 -and $elapsed % 20 -eq 0 -and $elapsed -ne $script:lastTick) {
            $script:lastTick = $elapsed
            Write-Host "      已等待 $elapsed 秒…" -ForegroundColor DarkGray
        }

        if ($elapsed -gt 600) {
            throw '登录等待超过 10 分钟'
        }
        Start-Sleep -Seconds 1
    }
}

function Invoke-NewChat {
    try {
        Invoke-Cdp -Method 'Page.navigate' -Params @{ url = $CFG.Url } | Out-Null
    } catch {}
    Start-Sleep -Milliseconds 1800
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $p = (Invoke-Js $JS_PROBE) | ConvertFrom-Json
            if ($p.signed -and $p.hasInput) {
                Invoke-Js $JS_QUIET | Out-Null
                return $true
            }
        } catch {}
        Start-Sleep -Milliseconds 700
    }
    return $false
}

# ============================================================ 主循环
function Invoke-OneTask {
    param([string]$Task)

    Write-Host ''
    Write-Host '  思考中…' -ForegroundColor DarkGray

    Invoke-NewChat | Out-Null

    $prompt = $SYS + "`n`n[用户任务]`n" + $Task
    if ($prompt.Length -gt $CFG.MaxInputLen) {
        $prompt = $SYS + "`n`n[用户任务]`n" + $Task.Substring(0, $CFG.MaxInputLen)
    }

    $reply = Invoke-Ask $prompt
    $turn = 0
    $acted = $false

    while ($turn -lt $CFG.MaxTurns) {
        $turn++
        $call = Get-ToolCall $reply
        if (-not $call) { break }

        $tname = [string]$call.name
        $label = $tname
        if ($call.command) { $label = "$tname · $($call.command)" }
        elseif ($call.path) { $label = "$tname · $($call.path)" }
        $label = $label -replace "`r?`n", ' '
        if ($label.Length -gt 96) { $label = $label.Substring(0, 96) + '…' }

        Write-Host ''
        Write-Host "  [$turn] $label" -ForegroundColor DarkCyan

        $result = Invoke-Tool $call
        $acted = $true

        $preview = $result -replace "`r?`n", ' '
        if ($preview.Length -gt 110) { $preview = $preview.Substring(0, 110) + '…' }
        Write-Host "      $preview" -ForegroundColor DarkGray

        $back = "<result>`n" + $result + "`n</result>"
        $reply = Invoke-Ask $back
    }

    $final = Get-CleanReply $reply
    if ($final.Length -gt 0) {
        Write-Host ''
        Write-Host $final -ForegroundColor White
        Write-Host ''
    }
    elseif (-not $acted) {
        Write-Host ''
        Write-Host '（模型没有返回内容，换个说法再试一次）' -ForegroundColor DarkYellow
        Write-Host ''
    }
    else {
        # 已经执行过工具、但模型这一轮没给文字总结。以前这种情况什么都不打印，
        # 看起来像「卡死」或「没反应」，容易让人以为出错。
        Write-Host ''
        Write-Host '（命令已执行完，模型这次没有给出总结）' -ForegroundColor DarkYellow
        Write-Host '  可以接着追问，例如「刚才的结果是什么」。' -ForegroundColor DarkGray
        Write-Host ''
    }
}

function Start-Agent {
    if ($env:WHIMSY_ONESHOT) {
        try { Invoke-OneTask $env:WHIMSY_ONESHOT }
        catch { N-Bad $_.Exception.Message }
        return
    }

    Write-Host ''
    Write-Host '  直接敲任务，例如：' -ForegroundColor DarkGray
    Write-Host '    · 看看这台电脑的配置' -ForegroundColor DarkGray
    Write-Host '    · 在桌面新建一个 hello.txt，写上今天日期' -ForegroundColor DarkGray
    Write-Host '  输入 exit 退出' -ForegroundColor DarkGray
    Write-Host ''

    while ($true) {
        Write-Host '你 > ' -ForegroundColor Cyan -NoNewline
        $task = Read-Host

        if ([string]::IsNullOrWhiteSpace($task)) { continue }
        if ($task -match '^(exit|quit|q|退出|再见)$') { break }

        try { Invoke-OneTask $task }
        catch {
            Write-Host ''
            N-Bad $_.Exception.Message
            Write-Host '  可以重新输入任务；如果一直失败，退出后重跑一次命令。' -ForegroundColor DarkGray
            Write-Host ''
            $script:lastTick = -1
        }
    }
}

# ============================================================ 入口
Show-Banner
Write-Host '  [1/3] 启动浏览器' -ForegroundColor Cyan
Start-Browser

Write-Host ''
Write-Host '  [2/3] 检查登录状态' -ForegroundColor Cyan

# 诊断模式：只检查浏览器与登录态，不进入对话（排查问题时很有用）
if ($env:WHIMSY_PROBE_ONLY) {
    try {
        $probe = $null
        for ($i = 0; $i -lt 30; $i++) {
            $probe = (Invoke-Js $JS_PROBE) | ConvertFrom-Json
            if ($probe.signed -or $probe.url -like '*sign_in*') { break }
            Start-Sleep -Milliseconds 500
        }
        if ($probe.signed) { N-Ok "登录态有效  $($probe.url)" }
        else { N-Warn "未登录，当前页面 $($probe.url)" }
    }
    catch { N-Bad "探测失败：$($_.Exception.Message)" }
    Close-Cdp
    try { if ($script:BrowserProc) { $script:BrowserProc.Kill() } } catch {}
    Write-Host ''
    return
}

Wait-SignedIn | Out-Null
N-Ok '已登录 DeepSeek'

Write-Host ''
Write-Host '  [3/3] 就绪' -ForegroundColor Cyan
N-Ok "当前目录  $(Get-Location)"
Write-Host ''

try {
    Start-Agent
}
finally {
    Write-Host ''
    Write-Host '  正在关闭浏览器…' -ForegroundColor DarkGray
    Close-Cdp
    try {
        if ($script:BrowserProc) { $script:BrowserProc.Kill() }
    } catch {}
    Write-Host '  已退出。下次运行会沿用这次的登录状态。' -ForegroundColor Green
    Write-Host ''
}
