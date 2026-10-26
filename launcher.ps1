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

function Test-Http {
    param([int]$Port, [string]$Path = '/')
    try {
        $req = [System.Net.HttpWebRequest]::Create(('http://127.0.0.1:{0}{1}' -f $Port, $Path))
        $req.Proxy = $null            # 关键：不走系统/环境代理，直连本机
        $req.Timeout = 1500
        $req.ReadWriteTimeout = 1500
        $req.Method = 'GET'
        $req.KeepAlive = $false
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return ($code -eq 200)
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
    if (Test-Http $p) { $port = $p; break }
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
            if (Test-Http $p) { $port = $p; break }
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

$edge = Find-Edge
try {
    if ($edge) {
        # App 形式（无地址栏）。沿用现有 Edge 配置：新建独立 profile 会触发 Edge 首次运行欢迎页，
        # 反而看不到应用窗口（实测：新 profile 里没有 "First Run" 标记 = 走了欢迎流程）。
        $edgeArgs = @(
            "--app=$url",
            '--window-size=1120,860',
            '--no-first-run',
            '--no-default-browser-check'
        )
        Start-Process -FilePath $edge -ArgumentList $edgeArgs | Out-Null
        Write-Log "opened in Edge app mode: $url"
    } else {
        Start-Process -FilePath $url | Out-Null
        Write-Log "edge not found; opened in default browser: $url"
    }
} catch {
    Write-Log "app-mode open failed: $($_.Exception.Message); falling back to normal window"
    try {
        if ($edge) {
            Start-Process -FilePath $edge -ArgumentList @('--new-window', $url) | Out-Null
        } else {
            Start-Process -FilePath $url | Out-Null
        }
    } catch {
        Write-Log "fallback open failed: $($_.Exception.Message)"
    }
}
