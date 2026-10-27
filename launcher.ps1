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
            Write-Log "opened in Chrome app mode: $Url (profile=$pf)"
            return $true
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
