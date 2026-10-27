$ErrorActionPreference = 'Stop'

# 工作台启动器
#
# 启动路径按"关键路径最短"排序，每一步都对应一次真实故障：
#  1) 单实例互斥 —— 双击两次时两个启动器会互相 Close 对方刚打开的窗口
#  2) 路径解析结果缓存在 env.json —— 每次 Get-Command 扫 PATH 要几百毫秒
#  3) 先按 TCP 快速判断端口，再用 /api/health 的 portal 标识确认身份
#     —— 不能只看端口是否 200（8787 上可能跑着别的服务）
#  4) 门户服务「立刻拉起」，再用 TCP 监听当就绪信号
#     —— 不先等 HTTP 200，也不对空端口盲等；浏览器可以在监听一出现就启动，两件事并行
#  5) 用 Start-Process -PassThru 拿进程号，再用 EnumWindows 按 PID 等窗口
#     —— .NET 的 MainWindowHandle 对 Chrome 应用窗口不可靠，会误判"没窗口"
#  6) 等窗口标题变成工作台标题 —— 标题还是 127.0.0.1 说明页面没加载，不是渲染问题
#  7) 置前 + 只在「窗口在最前、未被遮挡」时采像素 —— 否则拷到的是别人的像素
#  8) 判黑屏要连续两次；仍黑才降级软件合成重开；失败存诊断包并退 Edge/默认浏览器

$root = $PSScriptRoot
$portalPage = Join-Path $root '电工猴的此思妙想工作台.html'
$serverPy = Join-Path $root 'portal_server.py'
$logPath = Join-Path $root 'portal_launcher.log'
$diagRoot = Join-Path $root 'docs\diag'
$grabScript = Join-Path $root 'tools\grab_screen.py'
$stateDir = Join-Path $env:LOCALAPPDATA 'DianGongHouWorkbench'
$cacheFile = Join-Path $stateDir 'env.json'
$profileDir = Join-Path $stateDir 'ChromeApp'
$pageTitleHint = '电工猴'
$startedAt = Get-Date

function Write-Log {
    param([string]$Message)
    try {
        $elapsed = ((Get-Date) - $startedAt).TotalSeconds
        $line = '{0}  [+{1,6:0.00}s] {2}' -f (Get-Date -Format 'HH:mm:ss.fff'), $elapsed, $Message
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
    param([int]$Port, [int]$TimeoutMs = 200)
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $i = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $i.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $ok) { $c.Close(); return $false }
        $c.EndConnect($i)
        $c.Close()
        return $true
    } catch { return $false }
}

function Wait-Port {
    # 60ms 粒度：服务一监听就返回，不用等到下一个整秒
    param([int]$Port, [int]$Seconds = 40)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Port $Port 100) { return $true }
        Start-Sleep -Milliseconds 60
    }
    return $false
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

function Get-CachedPath {
    # 上次解析出来的程序路径，命中就省掉 Get-Command 扫 PATH 的时间
    param([string]$Key)
    try {
        if (Test-Path -LiteralPath $cacheFile) {
            $cache = Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $value = [string]$cache.$Key
            if ($value -and (Test-Path -LiteralPath $value)) { return $value }
        }
    } catch { }
    return $null
}

function Set-CachedPath {
    param([string]$Key, [string]$Value)
    try {
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        $cache = @{}
        if (Test-Path -LiteralPath $cacheFile) {
            try {
                $existing = Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($prop in $existing.PSObject.Properties) { $cache[$prop.Name] = $prop.Value }
            } catch { }
        }
        $cache[$Key] = $Value
        ($cache | ConvertTo-Json -Compress) | Set-Content -LiteralPath $cacheFile -Encoding UTF8
    } catch { }
}

function Find-Pythonw {
    $cached = Get-CachedPath -Key 'pythonw'
    if ($cached) { return $cached }
    if ($env:PYTHONW_PATH -and (Test-Path -LiteralPath $env:PYTHONW_PATH)) {
        Set-CachedPath -Key 'pythonw' -Value $env:PYTHONW_PATH
        return $env:PYTHONW_PATH
    }
    $cmd = Get-Command 'pythonw.exe' -ErrorAction SilentlyContinue
    if ($cmd) {
        Set-CachedPath -Key 'pythonw' -Value $cmd.Source
        return $cmd.Source
    }
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
            if ($found) {
                Set-CachedPath -Key 'pythonw' -Value $found
                return $found
            }
        }
    }
    return $null
}

function Find-Chrome {
    $cached = Get-CachedPath -Key 'chrome'
    if ($cached) { return $cached }
    $cands = @(
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')
    )
    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf86) { $cands += (Join-Path $pf86 'Google\Chrome\Application\chrome.exe') }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            Set-CachedPath -Key 'chrome' -Value $c
            return $c
        }
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
    $pids = @()
    if ($script:launchedPid) { $pids += [int]$script:launchedPid }
    try {
        $pids += @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*DianGongHouWorkbench*' } |
            ForEach-Object { $_.ProcessId })
    } catch { }
    return @($pids | Sort-Object -Unique)
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
    Start-Sleep -Milliseconds 500
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
        # 下面是"少干活"开关：应用窗口不需要组件更新/后台联网/扩展/崩溃上报，
        # 关掉能省掉启动时的后台任务与网络等待
        '--disable-background-networking',
        '--disable-component-update',
        '--disable-default-apps',
        '--disable-extensions',
        '--no-service-autorun',
        '--no-pings',
        '--disable-breakpad',
        '--metrics-recording-only',
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
            Start-Sleep -Milliseconds 100
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

function Open-ChromeWindow {
    # 打开并确认窗口出现。窗口由 python 侧用 EnumWindows 按进程号找
    # （.NET 的 MainWindowHandle 对 Chrome 应用窗口不可靠，会漏判成"没窗口"）。
    param([string]$Url, [string]$Extra = '')
    for ($try = 1; $try -le 3; $try++) {
        $proc = Start-ChromeApp -Url $Url -Extra $Extra
        if (-not $proc) { return $null }
        $script:launchedPid = $proc.Id
        $result = Invoke-WindowTool -Arguments @('--wait-window', '--pid', [string]$proc.Id, '--hint', $pageTitleHint, '--timeout', '12') -TimeoutSeconds 20
        if ($result -match '^HWND\s+(\d+)\s+(\d+)\s+(.*)$') {
            return [pscustomobject]@{
                Hwnd  = [IntPtr][int64]$matches[1]
                Pid   = [int]$matches[2]
                Title = $matches[3].Trim()
            }
        }
        Write-Log ("第 {0} 次启动：窗口查找结果 = {1}" -f $try, $result)
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
    # 等窗口标题变成页面标题，才认为页面真的加载出来了。
    # 页面没加载时标题是 "127.0.0.1_/"（实测），据此区分
    # "服务/代理没通导致空白窗口" 和 "页面画出来了但是黑屏"。
    # 这一步内部会顺手把窗口置前，省掉一次 pythonw 启动。
    param([IntPtr]$Hwnd, [int]$Seconds = 15)
    $result = Invoke-WindowTool -Arguments @('--wait-title', '--hwnd', [string]$Hwnd, '--hint', $pageTitleHint, '--timeout', [string]$Seconds) -TimeoutSeconds ($Seconds + 8)
    if ($result -match '^LOADED\s+(\d)\s+title=(.*)$') {
        return [pscustomobject]@{ Loaded = ($matches[1] -eq '1'); Title = $matches[2].Trim() }
    }
    return [pscustomobject]@{ Loaded = $false; Title = $result }
}

function Get-RenderVerdict {
    # 采样最坏情况约 3.3s（3 次尝试 × 置前 + 遮挡复检），8s 足够；
    # 给 20s 只会让"工具自己崩了"这种情况白等十几秒，看起来就是启动卡很久。
    param([IntPtr]$Hwnd)
    $result = Invoke-WindowTool -Arguments @('--check', '--hwnd', [string]$Hwnd, '--settle', '0.2') -TimeoutSeconds 8
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

# ---------- 1. 服务：立刻拉起，边跑边确认 ----------
$script:launchedPid = 0
$pythonw = Find-Pythonw
Write-Log ("启动器开始：pythonw={0}" -f $pythonw)

$port = 0
$serverProc = $null
$busy = $false

# 只有端口已经有人在听，才去问身份；避免对空端口发 HTTP 请求白等
if (Test-Port 8770 120) {
    if (Test-Portal 8770) {
        $port = 8770
        Write-Log '复用已在运行的门户（8770）'
    } else {
        $busy = $true
        Write-Log '8770 被别的程序占用，改从 8771 起'
    }
}

if ($port -eq 0 -and $pythonw) {
    $launchPort = 8770
    if ($busy) { $launchPort = 8771 }
    try {
        $argline = '-u "{0}" --port {1}' -f $serverPy, $launchPort
        $serverProc = Start-Process -FilePath $pythonw -ArgumentList $argline -WorkingDirectory $root -WindowStyle Hidden -PassThru
        Write-Log ("已拉起门户服务，端口 {0}" -f $launchPort)
    } catch {
        Write-Log "拉起门户服务失败：$($_.Exception.Message)"
    }
    if ($serverProc -and (Wait-Port $launchPort 40)) {
        $port = $launchPort
    } elseif ($serverProc) {
        # 服务工作线程可能挪到了后面的端口（被占），扫一遍确认
        for ($p = 8770; $p -le 8790; $p++) {
            if ((Test-Port $p 100) -and (Test-Portal $p)) { $port = $p; break }
        }
        if ($port -gt 0) { Write-Log ("门户实际监听在 {0}" -f $port) }
        else { Write-Log '门户服务 40 秒内没有可用端口' }
    }
}

if ($port -gt 0) {
    $url = 'http://127.0.0.1:{0}/' -f $port
    Write-Log ("门户已就绪：{0}" -f $url)
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

    $loaded = Wait-PageLoaded -Hwnd $window.Hwnd -Seconds 15
    Write-Log ("第 {0} 轮：页面加载={1} 标题={2}" -f $attempt, $loaded.Loaded, $loaded.Title)
    if (-not $loaded.Loaded) {
        $pageStuck = $true
        break
    }

    $verdict = Get-RenderVerdict -Hwnd $window.Hwnd
    if ($verdict -eq 'OCCLUDED') {
        $verdict = Get-RenderVerdict -Hwnd $window.Hwnd
    }
    if ($verdict -eq 'OK') {
        Write-Log ("第 {0} 轮：渲染正常，启动成功" -f $attempt)
        $succeeded = $true
        break
    }
    if ($verdict -eq 'BLACK') {
        # 首帧可能还没上屏，等一拍再判一次
        Start-Sleep -Milliseconds 500
        $verdict = Get-RenderVerdict -Hwnd $window.Hwnd
        if ($verdict -eq 'OK') {
            Write-Log ("第 {0} 轮：渲染正常（复检），启动成功" -f $attempt)
            $succeeded = $true
            break
        }
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

$totalSeconds = ((Get-Date) - $startedAt).TotalSeconds
if ($succeeded) { $resultText = '成功' } else { $resultText = '失败' }
Write-Log ('启动流程结束：总耗时 {0:0.00}s，结果={1}' -f $totalSeconds, $resultText)

try {
    if ($mutex -and $holdsLock) { [void]$mutex.ReleaseMutex() }
} catch { }
