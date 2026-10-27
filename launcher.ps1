$ErrorActionPreference = 'Stop'

# 工作台启动器
# 1) 拉起本地门户服务 portal_server.py（pythonw，后台）
# 2) 用「不经过系统代理」的 HTTP 请求确认门户页真的返回 200
# 3) 确认无误后再交给浏览器打开 —— 避免浏览器拿到未就绪的地址而显示错误页
# 4) 若服务起不来，退化为直接打开本地 HTML（页面仍能看，只是启动按钮不可用）

$root = $PSScriptRoot
$portalPage = Join-Path $root '电工猴的此思妙想工作台.html'
$serverPy = Join-Path $root 'portal_server.py'
$logPath = Join-Path $root 'portal_launcher.log'

function Write-Log {
    param([string]$Message)
    try {
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch { }
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

function Close-PortalChrome {
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*DianGongHouWorkbench*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Test-BlackScreen {
    # 用屏幕像素判断是否真黑屏（CDP 截图和窗口句柄都看不出黑屏）
    # 返回 $true=黑屏 / $false=正常 / $null=无法判断
    # 注意：不能用 Start-Process -RedirectStandardOutput——环境里同时存在
    # http_proxy 和 HTTP_PROXY 时，PowerShell 构造环境块会抛"关键字重复"。
    $grab = Join-Path $root 'tools\grab_screen.py'
    $pyw = Find-Pythonw
    if (-not $pyw -or -not (Test-Path -LiteralPath $grab)) { return $null }
    $outFile = Join-Path $env:TEMP 'wb_pixel_check.txt'
    try {
        if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue }
        Start-Process -FilePath $pyw -ArgumentList @($grab, '--check', '--out', $outFile) -WindowStyle Hidden | Out-Null
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 200
            if (Test-Path -LiteralPath $outFile) { break }
        }
        if (-not (Test-Path -LiteralPath $outFile)) {
            Write-Log "pixel check produced no result"
            return $null
        }
        $out = ([string](Get-Content -LiteralPath $outFile -Raw)).Trim()
        if ($out -match '^BLACK') { return $true }
        if ($out -match '^OK') { return $false }
        Write-Log "pixel check inconclusive: $out"
        return $null
    } catch {
        Write-Log "pixel check failed: $($_.Exception.Message)"
        return $null
    }
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

$pythonw = $null
if (Test-Path -LiteralPath $serverPy) { $pythonw = Find-Pythonw }

$port = 0
for ($p = 8770; $p -le 8790; $p++) {
    if (Test-Portal $p) { $port = $p; break }
}

if ($port -eq 0 -and $pythonw) {
    for ($p = 8770; $p -le 8790; $p++) {
        if (Test-Port $p) { continue }
        try {
            $argline = '-u "{0}" --port {1}' -f $serverPy, $p
            Start-Process -FilePath $pythonw -ArgumentList $argline -WorkingDirectory $root -WindowStyle Hidden | Out-Null
            Write-Log "started portal server on $p (pid process spawned)"
        } catch {
            Write-Log "failed to start portal server on ${p}: $($_.Exception.Message)"
            continue
        }
        $deadline = (Get-Date).AddSeconds(25)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
            if (Test-Portal $p) { $port = $p; break }
        }
        if ($port -gt 0) { break }
        Write-Log "portal server on $p did not answer within 25s"
    }
}

if ($port -gt 0) {
    $url = 'http://127.0.0.1:{0}/' -f $port
    Write-Log "portal ready at $url"
} else {
    $url = $portalPage
    Write-Log "portal server unavailable; falling back to local file"
}

if ($env:WB_LAUNCHER_TEST -eq '1') {
    Write-Output ('PYTHONW=' + $pythonw)
    Write-Output ('PORT=' + $port)
    Write-Output ('URL=' + $url)
    exit 0
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

function Wait-AppWindow {
    # 验证"窗口真的出来了"：既有本 profile 的 Chrome 进程，且有可见主窗口句柄。
    # 只 Start-Process 不验证 = 失败了也无声无息（之前 --disable-gpu 那样）。
    param([int]$Seconds = 8)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $ids = (Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -like '*DianGongHouWorkbench*' }).ProcessId
            if ($ids) {
                $win = Get-Process -Id $ids -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }
                if ($win) { return $true }
            }
        } catch { }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Open-AppWindow {
    param([string]$Url)

    # 优先 Chrome：它支持「独立实例 + --app」，能稳定开出无地址栏的应用窗口。
    # Edge 是单实例模型，--app 会被转发给已运行的 Edge 而退化成普通窗口（实测确认）。
    $chrome = Find-Chrome
    if ($chrome) {
        $pf = Join-Path $env:LOCALAPPDATA 'DianGongHouWorkbench\ChromeApp'
        try {
            New-Item -ItemType Directory -Force -Path $pf | Out-Null
            # 预置 First Run 标记，否则会走首次运行欢迎页，应用窗口被欢迎页盖住
            $sentinel = Join-Path $pf 'First Run'
            if (-not (Test-Path -LiteralPath $sentinel)) {
                New-Item -ItemType File -Path $sentinel -Force | Out-Null
            }
            # 清理上次异常退出留下的单实例锁，否则新实例会立刻退出
            Get-ChildItem -LiteralPath $pf -Filter 'Singleton*' -Force -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
            for ($attempt = 1; $attempt -le 2; $attempt++) {
                $a = @(
                    "--app=$Url",
                    '--window-size=1120,860',
                    '--window-position=120,80',
                    ('--user-data-dir="{0}"' -f $pf),
                    '--no-first-run',
                    '--no-default-browser-check',
                    '--disable-sync'
                )
                Start-Process -FilePath $chrome -ArgumentList $a | Out-Null
                if (-not (Wait-AppWindow -Seconds 8)) {
                    Write-Log "attempt ${attempt}: window not detected"
                    continue
                }
                $black = Test-BlackScreen
                if ($black -eq $true -and $attempt -lt 2) {
                    Write-Log "attempt ${attempt}: window renders black; restarting chrome"
                    Close-PortalChrome
                    Start-Sleep -Milliseconds 1200
                    continue
                }
                if ($black -eq $true) {
                    Write-Log "attempt ${attempt}: still black; giving up on chrome"
                    break
                }
                $pixel = 'skipped'
                if ($black -eq $false) { $pixel = 'ok' }
                Write-Log "chrome app window ready: $Url (attempt $attempt, pixel=$pixel)"
                return $true
            }
            Close-PortalChrome
            Write-Log "chrome window unusable; falling back to Edge/default browser"
        } catch {
            Write-Log "chrome app mode failed: $($_.Exception.Message)"
        }
    }

    $edge = Find-Edge
    if ($edge) {
        try {
            Start-Process -FilePath $edge -ArgumentList @("--app=$Url", '--window-size=1120,860', '--window-position=120,80') | Out-Null
            Write-Log "opened in Edge app mode: $Url"
            return $true
        } catch {
            Write-Log "edge app mode failed: $($_.Exception.Message)"
        }
        try {
            Start-Process -FilePath $edge -ArgumentList @('--new-window', $Url) | Out-Null
            Write-Log "opened in Edge normal window: $Url"
            return $true
        } catch {
            Write-Log "edge normal window failed: $($_.Exception.Message)"
        }
    }

    try {
        Start-Process -FilePath $Url | Out-Null
        Write-Log "opened in default browser: $Url"
        return $true
    } catch {
        Write-Log "open failed: $($_.Exception.Message)"
        return $false
    }
}

[void](Open-AppWindow -Url $url)
