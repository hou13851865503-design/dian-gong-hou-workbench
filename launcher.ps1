$ErrorActionPreference = 'Stop'

# 工作台启动器
# 作用：拉起本地门户服务（portal_server.py），然后用 Edge 应用窗口打开门户页。
# 这样界面就是网页门户本身（原生 DPI 渲染，清晰；与 GitHub 上的截图一致），
# 且门户里的「打开」按钮能真正启动两个应用（由本地服务负责）。
# 若找不到 Python，则退化为直接用浏览器打开门户文件（此时「打开」按钮不可用）。

$root = $PSScriptRoot
$portalPage = Join-Path $root '电工猴的此思妙想工作台.html'
$serverPy = Join-Path $root 'portal_server.py'

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
    try {
        $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/api/health" -f $Port) -TimeoutSec 2 -UseBasicParsing
        return ($r.StatusCode -eq 200)
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

$serverPort = 0
for ($p = 8770; $p -le 8790; $p++) {
    if (Test-Portal $p) { $serverPort = $p; break }
}

if ($serverPort -eq 0 -and $pythonw) {
    for ($p = 8770; $p -le 8790; $p++) {
        if (Test-Port $p) { continue }
        try {
            $argline = '-u "{0}" --port {1}' -f $serverPy, $p
            Start-Process -FilePath $pythonw -ArgumentList $argline -WorkingDirectory $root -WindowStyle Hidden | Out-Null
        } catch { continue }
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 200
            if (Test-Portal $p) { $serverPort = $p; break }
        }
        if ($serverPort -gt 0) { break }
    }
}

if ($serverPort -gt 0) {
    $url = "http://127.0.0.1:$serverPort/"
    $target = $url
} else {
    $url = $portalPage
    $target = ([System.Uri]$portalPage).AbsoluteUri
}

if ($env:WB_LAUNCHER_TEST -eq '1') {
    Write-Output "PYTHONW=$pythonw"
    Write-Output "PORT=$serverPort"
    Write-Output "URL=$url"
    exit 0
}

$edge = Find-Edge
if ($edge) {
    Start-Process -FilePath $edge -ArgumentList @("--app=$target", '--window-size=1120,840')
} else {
    Start-Process -FilePath $url
}
