$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$root = $PSScriptRoot
$aiRoot = Join-Path $root 'apps\domestic-global-ai-workbench'
$aiExe = Join-Path $aiRoot 'AI多Agent流水线.exe'
$homeworkRoot = Join-Path $root 'apps\qq-email-homework-assistant'
$homeworkScript = Join-Path $homeworkRoot 'app.pyw'
$iconPath = Join-Path $root '电工猴的此思妙想工作台-高清.ico'

$form = New-Object System.Windows.Forms.Form
$form.Text = '电工猴的此思妙想工作台'
$form.ClientSize = New-Object System.Drawing.Size(660, 410)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 247)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
if (Test-Path -LiteralPath $iconPath) {
    $form.Icon = New-Object System.Drawing.Icon($iconPath)
}

$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size = New-Object System.Drawing.Size(660, 112)
$header.BackColor = [System.Drawing.Color]::FromArgb(31, 52, 43)
$form.Controls.Add($header)

$heading = New-Object System.Windows.Forms.Label
$heading.Text = '电工猴的此思妙想工作台'
$heading.Location = New-Object System.Drawing.Point(30, 25)
$heading.Size = New-Object System.Drawing.Size(590, 35)
$heading.ForeColor = [System.Drawing.Color]::White
$heading.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 19, [System.Drawing.FontStyle]::Bold)
$header.Controls.Add($heading)

$subheading = New-Object System.Windows.Forms.Label
$subheading.Text = '应用中心'
$subheading.Location = New-Object System.Drawing.Point(33, 69)
$subheading.Size = New-Object System.Drawing.Size(550, 22)
$subheading.ForeColor = [System.Drawing.Color]::FromArgb(197, 215, 205)
$header.Controls.Add($subheading)

$status = New-Object System.Windows.Forms.Label
$status.Text = ' '
$status.Location = New-Object System.Drawing.Point(28, 372)
$status.Size = New-Object System.Drawing.Size(600, 22)
$status.ForeColor = [System.Drawing.Color]::FromArgb(82, 99, 90)
$status.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.Controls.Add($status)

function New-AppRow {
    param(
        [int]$Top,
        [string]$Title,
        [string]$Detail,
        [System.EventHandler]$OnClick
    )

    $row = New-Object System.Windows.Forms.Panel
    $row.Location = New-Object System.Drawing.Point(24, $Top)
    $row.Size = New-Object System.Drawing.Size(612, 98)
    $row.BackColor = [System.Drawing.Color]::White
    $row.BorderStyle = 'FixedSingle'

    $accent = New-Object System.Windows.Forms.Panel
    $accent.Location = New-Object System.Drawing.Point(0, 0)
    $accent.Size = New-Object System.Drawing.Size(4, 96)
    $accent.BackColor = [System.Drawing.Color]::FromArgb(71, 137, 101)
    $row.Controls.Add($accent)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.Location = New-Object System.Drawing.Point(22, 21)
    $titleLabel.Size = New-Object System.Drawing.Size(430, 24)
    $titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(32, 43, 37)
    $row.Controls.Add($titleLabel)

    $detailLabel = New-Object System.Windows.Forms.Label
    $detailLabel.Text = $Detail
    $detailLabel.Location = New-Object System.Drawing.Point(23, 54)
    $detailLabel.Size = New-Object System.Drawing.Size(430, 22)
    $detailLabel.ForeColor = [System.Drawing.Color]::FromArgb(103, 116, 108)
    $row.Controls.Add($detailLabel)

    $button = New-Object System.Windows.Forms.Button
    $button.Text = '打开'
    $button.Location = New-Object System.Drawing.Point(502, 27)
    $button.Size = New-Object System.Drawing.Size(86, 42)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = [System.Drawing.Color]::FromArgb(48, 112, 78)
    $button.ForeColor = [System.Drawing.Color]::White
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.Add_Click($OnClick)
    $row.Controls.Add($button)

    return $row
}

$aiAction = {
    if (-not (Test-Path -LiteralPath $aiExe)) {
        [System.Windows.Forms.MessageBox]::Show($form, "找不到应用文件：`n$aiExe", '无法打开', 'OK', 'Error') | Out-Null
        return
    }
    try {
        Start-Process -FilePath $aiExe -WorkingDirectory $aiRoot | Out-Null
        $status.Text = '已打开：国内外 AI 协同工作台'
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '启动失败', 'OK', 'Error') | Out-Null
    }
}.GetNewClosure()

$homeworkAction = {
    if (-not (Test-Path -LiteralPath $homeworkScript)) {
        [System.Windows.Forms.MessageBox]::Show($form, "找不到应用文件：`n$homeworkScript", '无法打开', 'OK', 'Error') | Out-Null
        return
    }

    $pythonw = $null
    if ($env:PYTHONW_PATH -and (Test-Path -LiteralPath $env:PYTHONW_PATH)) {
        $pythonw = $env:PYTHONW_PATH
    }
    if (-not $pythonw) {
        $pythonCommand = Get-Command 'pythonw.exe' -ErrorAction SilentlyContinue
        if ($pythonCommand) { $pythonw = $pythonCommand.Source }
    }
    if (-not $pythonw) {
        $installRoots = @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Python'),
            (Join-Path $env:ProgramFiles 'Python')
        )
        foreach ($installRoot in $installRoots) {
            if (Test-Path -LiteralPath $installRoot) {
                $candidate = Get-ChildItem -LiteralPath $installRoot -Directory -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending |
                    ForEach-Object { Join-Path $_.FullName 'pythonw.exe' } |
                    Where-Object { Test-Path -LiteralPath $_ } |
                    Select-Object -First 1
                if ($candidate) { $pythonw = $candidate; break }
            }
        }
    }
    if (-not $pythonw) {
        [System.Windows.Forms.MessageBox]::Show($form, '未找到 pythonw.exe。请安装 Python 3.9 或更新版本，或设置 PYTHONW_PATH。', '需要 Python', 'OK', 'Warning') | Out-Null
        return
    }

    try {
        Start-Process -FilePath $pythonw -ArgumentList ('"{0}"' -f $homeworkScript) -WorkingDirectory $homeworkRoot | Out-Null
        $status.Text = '已打开：QQ 邮箱作业班长助手'
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '启动失败', 'OK', 'Error') | Out-Null
    }
}.GetNewClosure()

$form.Controls.Add((New-AppRow -Top 136 -Title '国内外 AI 协同工作台' -Detail '多 Agent 任务协作' -OnClick $aiAction))
$form.Controls.Add((New-AppRow -Top 250 -Title 'QQ 邮箱作业班长助手' -Detail '作业收集与提交统计' -OnClick $homeworkAction))

[void]$form.ShowDialog()

