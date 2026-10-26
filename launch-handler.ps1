$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$arg = if ($args.Count -gt 0) { $args[0] } else { '' }
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-Pythonw {
    if ($env:PYTHONW_PATH -and (Test-Path -LiteralPath $env:PYTHONW_PATH)) { return $env:PYTHONW_PATH }
    $cmd = Get-Command 'pythonw.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($base in @((Join-Path $env:LOCALAPPDATA 'Programs\Python'), (Join-Path $env:ProgramFiles 'Python'))) {
        if (Test-Path -LiteralPath $base) {
            $cand = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName 'pythonw.exe' } |
                Where-Object { Test-Path -LiteralPath $_ } |
                Select-Object -First 1
            if ($cand) { return $cand }
        }
    }
    return $null
}

switch ($arg) {
    'workbench://homework' {
        $script = Join-Path $root 'apps\qq-email-homework-assistant\app.pyw'
        $dir = Split-Path -Parent $script
        $pw = Find-Pythonw
        if (-not $pw) {
            [System.Windows.Forms.MessageBox]::Show("未找到 pythonw.exe。`n请安装 Python 3.9+，或设置 PYTHONW_PATH 环境变量。", '需要 Python', 'OK', 'Warning') | Out-Null
            return
        }
        Start-Process -FilePath $pw -ArgumentList ('"{0}"' -f $script) -WorkingDirectory $dir | Out-Null
    }
    'workbench://ai' {
        $exe = Join-Path $root 'apps\domestic-global-ai-workbench\AI多Agent流水线.exe'
        Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) | Out-Null
    }
    'workbench://center' {
        $launcher = Join-Path $root 'launcher.ps1'
        Start-Process powershell -ArgumentList ('-STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $launcher) | Out-Null
    }
    default { }
}
