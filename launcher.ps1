$ErrorActionPreference = 'Stop'

# 工作台启动器
#
# 这套流程是踩了一年黑屏坑之后定下来的，每一步都对应一次真实故障：
#  1) 单实例互斥 —— 双击两次时两个启动器会互相 Close 对方刚打开的窗口
#  2) 先按 TCP 快速筛端口，再用 /api/health 的 portal 标识确认身份
#     —— 不能只看端口是否 200，也别对 21 个端口每个盲等 1.5 秒（那是几十秒空转）
#  3) 用 Start-Process -PassThru 拿到真实进程号认窗口，不依赖 WMI
#     —— 开机瞬间 WMI 可能很慢；而且 Chrome 偶尔会"启动即退出"（被上一个实例吞掉），
#        这种情况要能识别出来并重试，而不是干等 25 秒
#  4) 窗口出现后还要等「页面标题」变成工作台标题
#     —— 标题还是 127.0.0.1 说明页面根本没加载，这和"画出来了但是黑的"是两码事
#  5) 把窗口强制置前 —— 开机后一堆自启程序抢焦点，窗口在别人后面，用户就是"看不到"
#  6) 只有「窗口在最前、中心点属于自己」时采像素才有效
#     —— 否则拷到的是覆盖窗口的像素，会把正常页面误判成黑屏，进而杀掉好窗口
#  7) 判黑屏要连续两次、且先强制重绘；仍黑才降级为软件合成重开
#  8) 彻底失败时保存诊断包（截图/进程/环境/日志），再退 Edge 或默认浏览器

$root = $PSScriptRoot
$portalPage = Join-Path $root '电工猴的此思妙想工作台.html'
$serverPy = Join-Path $root 'portal_server.py'
$logPath = Join-Path $root 'portal_launcher.log'
$diagRoot = Join-Path $root 'docs\diag'
$grabScript = Join-Path $root 'tools\grab_screen.py'
$profileDir = Join-Path $env:LOCALAPPDATA 'DianGongHouWorkbench\ChromeApp'
# 页面标题里稳定出现的片段，用来判断"页面真的加载完了"
$pageTitleHint = '电工猴'
$startedAt = Get-Date

function Write-Log {
    param([string]$Message)
    try {
        $elapsed = ((Get-Date) - $startedAt).TotalSeconds
        $line = '{0}  [+{1,6:0.0}s] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $elapsed, $Message
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch { }
}

# ---------- 单实例互斥 ----------
$mutex = $null
$holdsLock = $true
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\DianGongHouWorkbenchLauncher')
    $holdsLock = $mutex.WaitOne(0)
} catch {
    $holdsLock = $true
}
if (-not $holdsLock) {
    Write-Log '另一个启动器正在运行，本次退出（避免两个实例互相杀掉对方的窗口）'
    exit 0
}

function Test-Port {
    param([int]$Port)
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $i = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $i.AsyncWaitHandle.WaitOne(200, $false)
        if (-not $ok) { $c.Close(); return $false }
        $c.EndConnect($i)
        $c.Close()
        return $true
    } catch { return $false }
}

function Test-Portal {
    param([int]$Port)
    # 只判断"/ 返回 200"会把别的本地服务（例如 8787 上的 New API）误认成门户，
    # 因此必须校验 /api/health 里的 portal 标识。
    try {
        $req = [System.Net.HttpWebRequest]::Create(('http://127.0.0.1:{0}/api/health' -f $Port))
        $req.Proxy = $null            # 不走系统/环境代理，直连本机
        $req.Timeout = 1200
        $req.ReadWriteTimeout = 1200
        $req.Method = 'GET'
        $req.KeepAlive = $false
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $reader.ReadToEnd()
        $reader.Close()
        $resp.Close()
        $data = $body | ConvertFrom-Json
        return ([string]$data.portal -eq 'workbench')
    } catch { return $false }
}

function Find-Pythonw {
    if ($env:PYTHONW_PATH -and (Test-Path -LiteralPath $env:PYTHONW_PATH)) { return $env:PYTHONW_PATH }
    $cmd = Get-Command 'pythonw.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python'),
        (Join-Path $env:ProgramFiles 'Python')
    )
    foreach ($r in $roots) {
        if ($r -and (Test-Path -LiteralPath $r)) {
            $found = Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName 'pythonw.exe' } |
                Where-Object { Test-Path -LiteralPath $_ } |
                Select-Object -First 1
            if ($found) { return $found }
        }
    }
    return $null
}

function Find-Python {
    $pw = Find-Pythonw
    if ($pw) {
        $py = Join-Path (Split-Path -Parent $pw) 'python.exe'
        if (Test-Path -LiteralPath $py) { return $py }
    }
    $cmd = Get-Command 'python.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Find-Chrome {
    $cands = @(
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')
    )
    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf86) { $cands += (Join-Path $pf86 'Google\Chrome\Application\chrome.exe') }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Find-Edge {
    $cands = @()
    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf86) { $cands += (Join-Path $pf86 'Microsoft\Edge\Application\msedge.exe') }
    if ($env:ProgramFiles) { $cands += (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe') }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Get-AppChromePids {
    # 优先用启动器自己拿到的进程号；WMI 只作补充（开机瞬间可能很慢甚至失败）
    $pids = @()
    if ($script:launchedPid) { $pids += [int]$script:launchedPid }
    try {
        $pids += @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*DianGongHouWorkbench*' } |
            ForEach-Object { $_.ProcessId })
    } catch { }
    return @($pids | Sort-Object -Unique)
}

function Get-AppWindows {
    # 只认「本应用窗口」：①启动器拉起的进程；②标题已是工作台标题；③标题还是纯 host（页面加载中）
    param($Proc)
    $list = @()
    $pids = @()
    if ($Proc -and -not $Proc.HasExited) { $pids += $Proc.Id }
    $pids += Get-AppChromePids
    foreach ($proc in @(Get-Process chrome -ErrorAction SilentlyContinue)) {
        if ($proc.MainWindowTitle -like "*$pageTitleHint*") { $pids += $proc.Id }
        elseif ($proc.MainWindowTitle -like '127.0.0.1*') { $pids += $proc.Id }
    }
    $pids = @($pids | Sort-Object -Unique)
    if ($pids.Count -eq 0) { return $list }
    foreach ($proc in @(Get-Process -Id $pids -ErrorAction SilentlyContinue)) {
        if ($proc -and $proc.MainWindowHandle -ne 0) {
            $list += [pscustomobject]@{
                Hwnd  = $proc.MainWindowHandle
                Pid   = $proc.Id
                Title = [string]$proc.MainWindowTitle
            }
        }
    }
    return $list
}

function Close-AppChrome {
    $pids = Get-AppChromePids
    foreach ($proc in @(Get-Process chrome -ErrorAction SilentlyContinue)) {
        if ($proc.MainWindowTitle -like "*$pageTitleHint*") { $pids += $proc.Id }
    }
    $pids = @($pids | Sort-Object -Unique)
    if ($pids.Count -eq 0) { return }
    foreach ($id in $pids) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
    Write-Log ("已关闭 {0} 个应用窗口进程：{1}" -f $pids.Count, ($pids -join ','))
    # 必须等旧实例真的退干净：Chrome 在退出的 1~2 秒内会把新启动的进程"吞掉"，
    # 新进程 ExitCode=0 且没有窗口，看起来就像"双击没反应"
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-Process chrome -ErrorAction SilentlyContinue).Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    }
    Start-Sleep -Milliseconds 600
    $script:launchedPid = 0
}

function Initialize-ChromeProfile {
    # 专用 profile 只存缓存，损坏了直接重建最省事。
    # 异常关机后 Local State / Preferences 可能被截断成半截 JSON，
    # Chrome 会打开一个空白窗口（深色主题下就是纯黑）。
    param([string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    $broken = $false
    foreach ($rel in @('Local State', 'Default\Preferences')) {
        $file = Join-Path $Path $rel
        if (Test-Path -LiteralPath $file) {
            try {
                $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8
                if ($raw -and $raw.Trim()) { $null = $raw | ConvertFrom-Json }
            } catch {
                $broken = $true
                Write-Log "profile 状态文件损坏：$rel"
            }
        }
    }
    if (Get-ChildItem -LiteralPath $Path -Filter 'Singleton*' -Force -ErrorAction SilentlyContinue) {
        $broken = $true
        Write-Log 'profile 残留单实例锁 Singleton*'
    }
    if ($broken) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        Write-Log 'profile 已重建'
    }
    Get-ChildItem -LiteralPath $Path -Filter 'Singleton*' -Force -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    $sentinel = Join-Path $Path 'First Run'
    if (-not (Test-Path -LiteralPath $sentinel)) {
        New-Item -ItemType File -Path $sentinel -Force | Out-Null
    }
}

function Start-ChromeApp {
    param([string]$Url, [string]$Extra = '')
    $chrome = Find-Chrome
    if (-not $chrome) { return $null }
    Initialize-ChromeProfile -Path $profileDir
    $a = @(
        ('--app={0}' -f $Url),
        '--window-size=1120,860',
        '--window-position=120,80',
        ('--user-data-dir="{0}"' -f $profileDir),
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-sync',
        '--no-proxy-server',
        '--disable-features=CalculateNativeWinOcclusion'
    )
    if ($Extra) { $a += $Extra }
    try {
        return (Start-Process -FilePath $chrome -ArgumentList $a -PassThru)
    } catch {
        Write-Log "启动 chrome 失败：$($_.Exception.Message)"
        return $null
    }
}

function Open-ChromeWindow {
    # 打开并确认窗口出现。窗口由 python 侧用 EnumWindows 按进程号找
    # （.NET 的 MainWindowHandle 对 Chrome 应用窗口不可靠，会漏判成"没窗口"）。
    param([string]$Url, [string]$Extra = '')
    for ($try = 1; $try -le 3; $try++) {
        $proc = Start-ChromeApp -Url $Url -Extra $Extra
        if (-not $proc) { return $null }
        $script:launchedPid = $proc.Id
        $result = Invoke-WindowTool -Arguments @('--wait-window', '--pid', [string]$proc.Id, '--hint', $pageTitleHint, '--timeout', '12') -TimeoutSeconds 25
        Write-Log ("第 {0} 次启动：窗口查找结果 = {1}" -f $try, $result)
        if ($result -match '^HWND\s+(\d+)\s+(\d+)\s+(.*)$') {
            return [pscustomobject]@{
                Hwnd  = [IntPtr][int64]$matches[1]
                Pid   = [int]$matches[2]
                Title = $matches[3].Trim()
            }
        }
        if ($proc.HasExited) {
            # 被上一个（正在退出的）实例吞掉了：等它彻底消失再试
            Write-Log ("第 {0} 次启动 chrome 立即退出（ExitCode={1}），退避后重试" -f $try, $proc.ExitCode)
            Start-Sleep -Milliseconds (900 * $try)
            continue
        }
        Write-Log ("第 {0} 次启动 chrome 12 秒内没有出现窗口" -f $try)
        return $null
    }
    return $null
}

function Wait-PageLoaded {
    # 窗口标题变成页面标题，才算页面真的加载出来了。
    # 页面没加载时标题是 "127.0.0.1"（实测），据此区分
    # "服务/代理没通导致空白窗口" 和 "页面画出来了但是黑屏"。
    param([IntPtr]$Hwnd, [int]$Seconds = 15)
    $result = Invoke-WindowTool -Arguments @('--wait-title', '--hwnd', [string]$Hwnd, '--hint', $pageTitleHint, '--timeout', [string]$Seconds) -TimeoutSeconds ($Seconds + 10)
    if ($result -match '^LOADED\s+(\d)\s+title=(.*)$') {
        return [pscustomobject]@{ Loaded = ($matches[1] -eq '1'); Title = $matches[2].Trim() }
    }
    return [pscustomobject]@{ Loaded = $false; Title = $result }
}

function Invoke-WindowTool {
    # 调 tools/grab_screen.py 的子命令；结果写文件（pythonw 下 stdout 不可用），
    # 每次用唯一文件名，避免读到上一次的残留结果。
    param([string[]]$Arguments, [int]$TimeoutSeconds = 20)
    $pyw = Find-Pythonw
    if (-not $pyw -or -not (Test-Path -LiteralPath $grabScript)) { return 'UNKNOWN' }
    $outFile = Join-Path $env:TEMP ('wb_probe_{0}.txt' -f [guid]::NewGuid().ToString('N'))
    $argList = @($grabScript) + $Arguments + @('--out', $outFile)
    try {
        Start-Process -FilePath $pyw -ArgumentList $argList -WindowStyle Hidden | Out-Null
    } catch {
        Write-Log "调用窗口工具失败：$($_.Exception.Message)"
        return 'UNKNOWN'
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    try {
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
            if (Test-Path -LiteralPath $outFile) { break }
        }
        if (-not (Test-Path -LiteralPath $outFile)) {
            Write-Log '窗口工具没有返回结果'
            return 'UNKNOWN'
        }
        return ([string](Get-Content -LiteralPath $outFile -Raw -Encoding UTF8)).Trim()
    } finally {
        if (Test-Path -LiteralPath $outFile) {
            Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Focus-AppWindow {
    param([IntPtr]$Hwnd)
    $result = Invoke-WindowTool -Arguments @('--focus', '--hwnd', [string]$Hwnd) -TimeoutSeconds 15
    Write-Log "置前结果：$result"
}

function Get-RenderVerdict {
    param([IntPtr]$Hwnd)
    $result = Invoke-WindowTool -Arguments @('--check', '--hwnd', [string]$Hwnd) -TimeoutSeconds 20
    Write-Log "像素判定：$result"
    if ($result -match '^BLACK') { return 'BLACK' }
    if ($result -match '^OK') { return 'OK' }
    if ($result -match '^OCCLUDED') { return 'OCCLUDED' }
    if ($result -match '^NOWINDOW') { return 'NOWINDOW' }
    return 'UNKNOWN'
}

function Save-Diagnostics {
    param([string]$Reason, [string]$Url)
    try {
        $dir = Join-Path $diagRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'reason.txt') -Value $Reason -Encoding UTF8

        $text = @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } |
            ForEach-Object { '{0,-8} {1}' -f $_.Id, $_.MainWindowTitle })
        Set-Content -LiteralPath (Join-Path $dir 'windows.txt') -Value ($text -join "`r`n") -Encoding UTF8

        $text = @(Get-AppChromePids | ForEach-Object { '{0}' -f $_ })
        Set-Content -LiteralPath (Join-Path $dir 'chrome-pids.txt') -Value ($text -join "`r`n") -Encoding UTF8

        $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        $text = @(
            ('ProxyEnable=' + $ie.ProxyEnable),
            ('ProxyServer=' + $ie.ProxyServer),
            ('AutoConfigURL=' + $ie.AutoConfigURL),
            ('env HTTP_PROXY=' + $env:HTTP_PROXY),
            ('env http_proxy=' + $env:http_proxy),
            ('chrome=' + (Find-Chrome)),
            ('pythonw=' + (Find-Pythonw)),
            ('url=' + $Url),
            ('pwsh=' + $PSVersionTable.PSVersion.ToString())
        )
        Set-Content -LiteralPath (Join-Path $dir 'env.txt') -Value ($text -join "`r`n") -Encoding UTF8

        if (Test-Path -LiteralPath $logPath) {
            Copy-Item -LiteralPath $logPath -Destination (Join-Path $dir 'launcher.log') -Force -ErrorAction SilentlyContinue
        }
        $shot = Join-Path $dir 'app-window.png'
        $pyw = Find-Pythonw
        if ($pyw -and (Test-Path -LiteralPath $grabScript)) {
            try {
                Start-Process -FilePath $pyw -ArgumentList @($grabScript, $pageTitleHint, $shot) -WindowStyle Hidden | Out-Null
                Start-Sleep -Milliseconds 1600
            } catch { }
        }
        Write-Log "诊断包已保存：$dir"
    } catch {
        Write-Log "保存诊断包失败：$($_.Exception.Message)"
    }
}

function Find-WindowByTitle {
    param([string]$Keyword)
    try {
        return @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -and $_.MainWindowTitle -like "*$Keyword*" })
    } catch { return @() }
}

# ---------- 1. 保证门户服务在跑 ----------
$script:launchedPid = 0
$pythonw = $null
if (Test-Path -LiteralPath $serverPy) { $pythonw = Find-Pythonw }
Write-Log ("启动器开始：pythonw={0} chrome={1}" -f $pythonw, (Find-Chrome))

$port = 0
# 常见情况：8770 上就是我们的门户，一次请求即可，不做 21 个端口的扫描
if (Test-Portal 8770) { $port = 8770 }
if ($port -eq 0 -and (Test-Port 8770)) {
    # 8770 被别的程序占了（例如 New API），往后找已经在跑的自己的实例
    for ($p = 8771; $p -le 8790; $p++) {
        if (-not (Test-Port $p)) { continue }
        if (Test-Portal $p) { $port = $p; break }
    }
}

if ($port -eq 0 -and $pythonw) {
    for ($p = 8770; $p -le 8790; $p++) {
        if (Test-Port $p) { continue }
        try {
            $argline = '-u "{0}" --port {1}' -f $serverPy, $p
            Start-Process -FilePath $pythonw -ArgumentList $argline -WorkingDirectory $root -WindowStyle Hidden | Out-Null
            Write-Log "已拉起门户服务，端口 $p"
        } catch {
            Write-Log "拉起门户服务失败（端口 ${p}）：$($_.Exception.Message)"
            continue
        }
        # 冷启动（刚开机、杀毒软件还在扫）可以很慢，给足 40 秒
        $deadline = (Get-Date).AddSeconds(40)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 300
            if (Test-Portal $p) { $port = $p; break }
        }
        if ($port -gt 0) { break }
        Write-Log "门户服务在 ${p} 端口 40 秒内没有响应"
    }
}

if ($port -gt 0) {
    $url = 'http://127.0.0.1:{0}/' -f $port
    Write-Log "门户已就绪：$url"
} else {
    $url = $portalPage
    Write-Log '门户服务不可用，退化为打开本地文件（启动按钮会不可用）'
}

if ($env:WB_LAUNCHER_TEST -eq '1') {
    Write-Output ('PYTHONW=' + $pythonw)
    Write-Output ('PORT=' + $port)
    Write-Output ('URL=' + $url)
    exit 0
}

# ---------- 2. 打开应用窗口（带判定与降级）----------
$succeeded = $false
$pageStuck = $false

for ($attempt = 1; $attempt -le 2; $attempt++) {
    if ($attempt -gt 1) {
        Close-AppChrome
    }
    $extra = ''
    if ($attempt -eq 2) {
        # 第一轮黑屏时换软件合成：绕开显卡/驱动冷启动时合成失败
        $extra = '--disable-gpu-compositing'
        Write-Log '第二轮改用软件合成重开'
    }
    $window = Open-ChromeWindow -Url $url -Extra $extra
    if (-not $window) {
        Write-Log ("第 {0} 轮：没有拿到应用窗口" -f $attempt)
        continue
    }
    Write-Log ("第 {0} 轮：窗口已出现 pid={1} 句柄={2}" -f $attempt, $window.Pid, $window.Hwnd)

    Focus-AppWindow -Hwnd $window.Hwnd

    $loaded = Wait-PageLoaded -Hwnd $window.Hwnd -Seconds 15
    Write-Log ("第 {0} 轮：页面加载={1} 标题={2}" -f $attempt, $loaded.Loaded, $loaded.Title)
    if (-not $loaded.Loaded) {
        # 窗口在、页面没加载 —— 这不是黑屏问题，重开窗口也没用
        $pageStuck = $true
        break
    }

    $verdict = Get-RenderVerdict -Hwnd $window.Hwnd
    if ($verdict -eq 'OCCLUDED') {
        Focus-AppWindow -Hwnd $window.Hwnd
        $verdict = Get-RenderVerdict -Hwnd $window.Hwnd
    }
    if ($verdict -eq 'BLACK') {
        # 首帧可能还没上屏，等一拍再判一次
        Start-Sleep -Milliseconds 900
        Focus-AppWindow -Hwnd $window.Hwnd
        $verdict = Get-RenderVerdict -Hwnd $window.Hwnd
    }
    if ($verdict -eq 'OK') {
        Write-Log ("第 {0} 轮：渲染正常，启动成功" -f $attempt)
        $succeeded = $true
        break
    }
    if ($verdict -eq 'BLACK') {
        Write-Log ("第 {0} 轮：连续采样都是黑屏" -f $attempt)
        continue
    }
    # OCCLUDED / UNKNOWN / NOWINDOW：窗口已置前但拿不到可信像素。
    # 此时绝不能杀进程——杀掉的往往是一个正常窗口。
    Write-Log ("第 {0} 轮：像素无法判定（{1}），保留窗口交给用户" -f $attempt, $verdict)
    $succeeded = $true
    break
}

# ---------- 3. 降级 ----------
if (-not $succeeded) {
    Save-Diagnostics -Reason ("chrome 应用窗口未通过校验（pageStuck={0}）" -f $pageStuck) -Url $url
}

if (-not $succeeded -and $pageStuck) {
    # 页面根本没加载出来：直接用默认浏览器打开本地文件，至少能进得去
    try {
        Start-Process -FilePath $portalPage | Out-Null
        Write-Log '页面未能从本地服务加载，已用默认浏览器打开本地文件'
        $succeeded = $true
    } catch {
        Write-Log "打开本地文件失败：$($_.Exception.Message)"
    }
}

if (-not $succeeded) {
    $edge = Find-Edge
    if ($edge) {
        try {
            Start-Process -FilePath $edge -ArgumentList @(('--app={0}' -f $url), '--window-size=1120,860', '--window-position=120,80') | Out-Null
            Write-Log "已尝试 Edge 应用窗口：$url"
            Start-Sleep -Milliseconds 2500
            # Edge 是单实例模型，--app 可能被已经在后台跑的 Edge 吞掉
            if ((Find-WindowByTitle -Keyword $pageTitleHint).Count -eq 0) {
                Start-Process -FilePath $edge -ArgumentList @('--new-window', $url) | Out-Null
                Write-Log 'Edge 没有出现应用窗口，改用普通窗口'
            }
            $succeeded = $true
        } catch {
            Write-Log "Edge 打开失败：$($_.Exception.Message)"
        }
    }
}

if (-not $succeeded) {
    try {
        Start-Process -FilePath $url | Out-Null
        Write-Log "已交给默认浏览器：$url"
        $succeeded = $true
    } catch {
        Write-Log "默认浏览器打开失败：$($_.Exception.Message)"
    }
}

if (-not $succeeded) {
    Write-Log '全部打开方式都失败，请查看 docs\diag 下的诊断包'
}

try {
    if ($mutex -and $holdsLock) { [void]$mutex.ReleaseMutex() }
} catch { }
